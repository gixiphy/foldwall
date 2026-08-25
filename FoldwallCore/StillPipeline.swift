//  StillPipeline.swift
//  每螢各自合成一張 JPEG 並掛上桌面。不碰 AppKit：NSScreen → DisplayTarget 的轉換在 app 層。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public protocol DesktopSetting: Sendable {
    /// async：合成在背景執行緒，寫桌布的實作自己跳回 main actor。
    func setDesktopImageURL(_ url: URL, for screenID: CGDirectDisplayID) async throws
}

/// 合成前把來源變成本機讀得到的檔案（File Provider 物化／SMB 拷貝）。
public protocol MediaPreparing: Sendable {
    func prepare(_ url: URL) async throws -> URL
}

public struct DisplayTarget: Sendable, Equatable {
    /// 執行期用；**不要**持久化（重開機／熱插拔會變）。
    public var id: CGDirectDisplayID
    /// 持久化用的穩定識別（CGDisplayCreateUUIDFromDisplayID）。
    public var uuid: String
    /// 像素尺寸（points × backingScaleFactor）。
    public var canvas: CGSize

    public init(id: CGDirectDisplayID, uuid: String, canvas: CGSize) {
        self.id = id
        self.uuid = uuid
        self.canvas = canvas
    }

    public static func canvasSize(frame: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: frame.width * scale, height: frame.height * scale)
    }
}

public struct StillPipeline: Sendable {

    public struct Outcome: Sendable, Equatable {
        public var written: [CGDirectDisplayID] = []
        public var skipped: [CGDirectDisplayID] = []
        /// 沒有任何可讀影像 → 保留現桌布、選單提示、下輪重試。
        public var poolWasEmpty = false
    }

    public static let jpegQuality: Double = 0.85
    /// 只留當前輪＋上一輪：系統可能仍持有上一輪 URL。
    public static let generationsKept = 2

    private let composer: any MontageComposing
    private let desktop: any DesktopSetting
    private let paths: AppPaths
    /// nil = 來源都在本機，不需物化。
    private let preparer: (any MediaPreparing)?

    public init(
        composer: any MontageComposing = MontageComposer(),
        desktop: any DesktopSetting,
        paths: AppPaths,
        preparer: (any MediaPreparing)? = nil
    ) {
        self.composer = composer
        self.desktop = desktop
        self.paths = paths
        self.preparer = preparer
    }

    /// 依螢幕長邊決定抽幾張；`reduced` 封頂 6。門檻定死，改了要連測試一起改。
    public static func pieceCount(longSide: CGFloat, tier: PowerTier) -> Int {
        let requested: Int
        switch longSide {
        case 5120...: requested = 10
        case 3456...: requested = 8
        default: requested = 6
        }
        return tier == .reduced ? min(6, requested) : requested
    }

    @discardableResult
    public func refresh(
        displays: [DisplayTarget],
        skipIDs: Set<CGDirectDisplayID>,
        pool: [URL],
        effect: PostProcess,
        tier: PowerTier,
        cycleNonce: UInt64
    ) async throws -> Outcome {
        var outcome = Outcome()
        guard tier != .paused else { return outcome }

        let targets = displays.filter { display in
            if skipIDs.contains(display.id) {
                outcome.skipped.append(display.id)
                return false
            }
            return true
        }
        guard !targets.isEmpty else { return outcome }

        try FileManager.default.createDirectory(at: paths.wallpapers, withIntermediateDirectories: true)

        for display in targets {
            let longSide = max(display.canvas.width, display.canvas.height)
            let count = Self.pieceCount(longSide: longSide, tier: tier)
            let seed = SeededGenerator.seed(cycleNonce: cycleNonce, displayUUID: display.uuid)

            let images = await loadImages(from: pool, count: count, seed: seed, maxPixel: Int(longSide))
            guard !images.isEmpty else {
                // 這台沒圖可用 → 保留現桌布，不寫黑圖
                outcome.poolWasEmpty = true
                continue
            }

            let composite = try composer.compose(
                images: images,
                canvas: display.canvas,
                recipe: MontageRecipe(pieceCount: count, seed: seed),
                effect: effect
            )
            let url = try write(composite, uuid: display.uuid, nonce: cycleNonce)
            try await desktop.setDesktopImageURL(url, for: display.id)
            outcome.written.append(display.id)
        }

        try? prune(currentNonce: cycleNonce)
        return outcome
    }

    // MARK: - 私有

    /// 依 seed 抽片並載入。**只物化抽中的**，不是整池下載。
    /// 壞檔／離線略過（視同離線），不讓一顆爛蘋果毀掉整輪。
    private func loadImages(from pool: [URL], count: Int, seed: UInt64, maxPixel: Int) async -> [CGImage] {
        guard !pool.isEmpty else { return [] }
        var rng = SeededGenerator(seed: seed)
        var images: [CGImage] = []
        var attempts = 0
        let budget = count * 3   // 壞檔多時不要無限重試

        while images.count < count, attempts < budget {
            attempts += 1
            let url = pool[Int.random(in: 0..<pool.count, using: &rng)]
            var local = url
            if let preparer {
                guard let prepared = try? await preparer.prepare(url) else { continue }
                local = prepared
            }
            if let image = try? ImageLoader.load(local, maxPixel: maxPixel) {
                images.append(image)
            }
        }
        return images
    }

    private func write(_ image: CGImage, uuid: String, nonce: UInt64) throws -> URL {
        // 每輪換檔名：setDesktopImageURL 對同一個 URL 是 no-op，同名覆寫桌布不會刷新
        let url = paths.wallpapers.appending(path: "\(uuid)-\(nonce).jpg")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }

        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: Self.jpegQuality,
        ] as CFDictionary)

        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    private func prune(currentNonce: UInt64) throws {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: paths.wallpapers,
                                               includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }

        // 檔名 <uuid>-<nonce>.jpg
        let nonces = Set(files.compactMap { url -> UInt64? in
            url.deletingPathExtension().lastPathComponent.split(separator: "-").last
                .flatMap { UInt64($0) }
        })
        let keep = Set(nonces.sorted(by: >).prefix(Self.generationsKept))

        for url in files {
            let nonce = url.deletingPathExtension().lastPathComponent
                .split(separator: "-").last.flatMap { UInt64($0) }
            if let nonce, !keep.contains(nonce) {
                try? fm.removeItem(at: url)
            }
        }
    }
}
