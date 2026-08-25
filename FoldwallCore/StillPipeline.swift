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

    /// 合成輸出的 JPEG 品質。
    ///
    /// **這裡可以壓，來源不行。** 來源要原圖（見 ImageTranscoder 與 4kwallpapers
    /// 取最大解析度）——那是還要再經過縮放與合成的素材，先掉畫質會一路帶下去。
    /// 但合成結果是終點，而且每片只佔畫面一部分，0.85 看不出差別。
    ///
    /// 這個數字直接乘上寫入量：5120×1440 的蒙太奇在 1.0 是 3.3 MB、0.85 是 1.4 MB，
    /// 而這條路每輪都要寫一次。
    public static let jpegQuality: Double = 0.85
    /// 只留當前輪＋上一輪：系統可能仍持有上一輪 URL。
    public static let generationsKept = 2
    /// 每要一張圖，最多試幾次（壞檔／離線／短邊不足都算一次）。
    public static let attemptsPerPiece = 6

    private let composer: any MontageComposing
    private let desktop: any DesktopSetting
    private let paths: AppPaths
    /// nil = 來源都在本機，不需物化。
    private let preparer: (any MediaPreparing)?
    /// 查「這個檔是誰拍的」。nil＝不標註（測試與純本機用法）。
    private let credits: (any CreditLookup)?

    public init(
        composer: any MontageComposing = MontageComposer(),
        desktop: any DesktopSetting,
        paths: AppPaths,
        preparer: (any MediaPreparing)? = nil,
        credits: (any CreditLookup)? = nil
    ) {
        self.composer = composer
        self.desktop = desktop
        self.paths = paths
        self.preparer = preparer
        self.credits = credits
    }

    /// 依螢幕長邊決定抽幾張；`reduced` 封頂 6。門檻定死，改了要連測試一起改。
    ///
    /// `override` 是使用者在設定裡指定的張數（nil＝自動）。指定值一樣要過
    /// `MontageComposer.pieceCountRange` 的夾擠與降載封頂——合成端本來就會夾，
    /// 在這裡先夾一次，UI 顯示的數字才會跟實際畫出來的一致。
    public static func pieceCount(
        longSide: CGFloat, tier: PowerTier, override: Int? = nil
    ) -> Int {
        let requested: Int
        if let override {
            requested = min(max(override, MontageComposer.pieceCountRange.lowerBound),
                            MontageComposer.pieceCountRange.upperBound)
        } else {
            switch longSide {
            case 5120...: requested = 10
            case 3456...: requested = 8
            default: requested = 6
            }
        }
        return tier == .reduced ? min(6, requested) : requested
    }

    @discardableResult
    public func refresh(
        displays: [DisplayTarget],
        skipIDs: Set<CGDirectDisplayID>,
        pool: SourcePool,
        effect: PostProcess,
        tier: PowerTier,
        cycleNonce: UInt64,
        pieceCountOverride: Int? = nil
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
            let count = Self.pieceCount(longSide: longSide, tier: tier,
                                        override: pieceCountOverride)
            let seed = SeededGenerator.seed(cycleNonce: cycleNonce, displayUUID: display.uuid)

            // 多要一張給背景：背景是低透明度鋪滿的那層，用掉一張片就會重複。
            // 池不夠時 loadImages 自然會少給，合成端會退回用第一張。
            let pieces = await loadPieces(from: pool, count: count + 1,
                                          seed: seed, maxPixel: Int(longSide))
            guard !pieces.isEmpty else {
                // 這台沒圖可用 → 保留現桌布，不寫黑圖
                outcome.poolWasEmpty = true
                continue
            }

            let composite = try composer.compose(
                pieces: pieces,
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
    /// 壞檔／離線／過小略過（視同離線），不讓一顆爛蘋果毀掉整輪。
    ///
    /// 短邊門檻在這裡驗而不是在索引時：索引只看副檔名（開檔太貴，見 MediaIndexer），
    /// 所以池裡會混著 icon 等雜訊圖，由這個迴圈當場換掉。
    ///
    /// **輪流抽而不是攤平隨機抽**：見 SourcePool。攤平的話張數多的來源會吃掉整張圖。
    private func loadPieces(from pool: SourcePool, count: Int, seed: UInt64, maxPixel: Int) async -> [MontagePiece] {
        guard !pool.isEmpty else { return [] }
        var rotation = SourceRotation(pool: pool, seed: seed)
        var images: [MontagePiece] = []
        var attempts = 0
        // 剔除從索引時挪到這裡後，撞到不合格的機率變高 → 預算跟著放寬。
        let budget = count * Self.attemptsPerPiece

        while images.count < count, attempts < budget {
            attempts += 1
            guard let url = rotation.next() else { break }
            var local = url
            if let preparer {
                guard let prepared = try? await preparer.prepare(url) else { continue }
                local = prepared
            }
            if let image = try? ImageLoader.load(
                local, maxPixel: maxPixel, minimumShortSide: MediaIndexer.minimumShortSide
            ) {
                // 出處要查**原始**的 url，不是物化後的本機副本
                images.append(MontagePiece(image: image, credit: credits?.credit(for: url)))
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
