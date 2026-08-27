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

    /// 解碼上限要為「橫幅」留的餘裕，見 `decodeMaxPixel`。
    ///
    /// 一片的**長邊** ＝ 短邊 × `maxPieceScale` × 該張的長寬比，而比例要解開才知道。
    /// 這裡按 16:9（1.78，桌布來源最常見的比例）抓、進位到 1.8：常見的橫幅圖在這個
    /// 上限下仍是原尺寸貼上，更寬的全景會被多縮一點——那是少數，不值得為它把每張
    /// 圖都解大一倍。
    public static let pieceAspectAllowance: CGFloat = 1.8

    /// 背景那張允許被放大幾倍，見 `decodeMaxPixel`。
    ///
    /// 背景走 `aspectFill` 鋪滿整張畫布，真正需要的是畫布**長邊**——但它是 0.22 alpha
    /// 疊在近黑底上的一層，放大一點看不出來（原始設計寫的本來就是「模糊鋪滿」）。
    /// 所以不按長邊解，只保證放大不超過這個倍數。
    ///
    /// **只擋得住橫幅背景。** 直式照片要鋪滿超寬畫布，`aspectFill` 本來就得放到更大，
    /// 那是 aspectFill 的本質，不是這個地板能解的。
    public static let backdropMaxUpscale: CGFloat = 2

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

    /// 依螢幕長邊決定張數**上限**；`reduced` 封頂 6。門檻定死，改了要連測試一起改。
    ///
    /// 這是上限不是實際張數——實際幾片每輪由 `drawnPieceCount` 在 `1...上限` 之間抽。
    ///
    /// 門檻比早期高（原本 10／8／6）：`MontageComposer.densityScale` 會讓片數多時
    /// 每片跟著縮小，總墨量不變，所以高張數不再是一團糊。
    ///
    /// `override` 是使用者在設定裡指定的上限（nil＝自動）。指定值一樣要過
    /// `MontageComposer.pieceCountRange` 的夾擠與降載封頂——合成端本來就會夾，
    /// 在這裡先夾一次，UI 顯示的數字才會跟實際畫出來的一致。
    public static func pieceCountCeiling(
        longSide: CGFloat, tier: PowerTier, override: Int? = nil
    ) -> Int {
        let requested: Int
        if let override {
            requested = min(max(override, MontageComposer.pieceCountRange.lowerBound),
                            MontageComposer.pieceCountRange.upperBound)
        } else {
            switch longSide {
            case 5120...: requested = 16
            case 3456...: requested = 12
            default: requested = 8
            }
        }
        return tier == .reduced ? min(6, requested) : requested
    }

    /// 這一輪這台螢幕實際要畫幾片：`1...ceiling` 均勻抽。
    ///
    /// 固定張數的蒙太奇看久了會發現「每次都差不多密」。讓張數自己變動，才會有時
    /// 只有一張大圖、有時鋪滿十幾張——這個變化本身就是效果的一部分。
    ///
    /// 用**獨立**的 RNG 串流（seed 再攪一次）而不是跟合成共用：構圖那條串流一旦
    /// 多抽少抽一個數，張數就會跟著變，兩件事會綁死在一起難以各自調整。
    public static func drawnPieceCount(ceiling: Int, seed: UInt64) -> Int {
        let top = min(max(ceiling, MontageComposer.pieceCountRange.lowerBound),
                      MontageComposer.pieceCountRange.upperBound)
        guard top > 1 else { return top }
        var rng = SeededGenerator(seed: seed ^ 0x5EED_C0DE_5EED_C0DE)
        return Int.random(in: 1...top, using: &rng)
    }

    /// 每張來源圖要解到多大（長邊像素）。
    ///
    /// **不是畫布長邊。** 一片最大只佔短邊 `MontageComposer.maxPieceScale`，按畫布
    /// 長邊解等於每張多解好幾倍面積——而 `loadPieces` 會把整輪的圖同時留在記憶體裡
    /// 直到合成結束：5K 畫布 × 11 張（10 片＋背景）原本是 ~770MB 的峰值，這個常駐
    /// 在選單列的 app 沒有理由付。
    ///
    /// 背景那張共用同一個上限，但有 `backdropMaxUpscale` 的地板墊著——它鋪滿整張
    /// 畫布，解太小會被放大到看得出來。超寬螢幕（短邊小、長邊大）就是靠這條地板。
    ///
    /// 只影響解析度，不影響構圖：同一個 seed 抽到的片、位置、背景都跟以前一樣。
    public static func decodeMaxPixel(canvas: CGSize, pieceCount: Int) -> Int {
        let shortSide = min(canvas.width, canvas.height)
        let longSide = max(canvas.width, canvas.height)
        // 片數多時每片會被 densityScale 縮小，該解的也跟著少——20 片的記憶體
        // 峰值才不會比 6 片高上三倍
        let piece = shortSide * MontageComposer.maxPieceScale
            * MontageComposer.densityScale(pieceCount: pieceCount) * pieceAspectAllowance
        let backdropFloor = longSide / backdropMaxUpscale
        // 直式或接近正方的畫布上這個式子會超過長邊——那時解到長邊就到頂了
        let capped = min(max(piece, backdropFloor), longSide)
        return max(1, Int(capped.rounded()))
    }

    @discardableResult
    public func refresh(
        displays: [DisplayTarget],
        skipIDs: Set<CGDirectDisplayID>,
        pool: SourcePool,
        effect: PostProcess,
        tier: PowerTier,
        cycleNonce: UInt64,
        pieceCountOverride: Int? = nil,
        showCredits: Bool = true
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
            let seed = SeededGenerator.seed(cycleNonce: cycleNonce, displayUUID: display.uuid)
            let ceiling = Self.pieceCountCeiling(longSide: longSide, tier: tier,
                                                 override: pieceCountOverride)
            let count = Self.drawnPieceCount(ceiling: ceiling, seed: seed)

            // 多要一張給背景：背景是低透明度鋪滿的那層，用掉一張片就會重複。
            // 池不夠時 loadImages 自然會少給，合成端會退回用第一張。
            let pieces = await loadPieces(
                from: pool, count: count + 1, seed: seed,
                maxPixel: Self.decodeMaxPixel(canvas: display.canvas, pieceCount: count),
                includeCredits: showCredits)
            guard !pieces.isEmpty else {
                // 這台沒圖可用 → 保留現桌布，不寫黑圖
                outcome.poolWasEmpty = true
                continue
            }

            let composite = try composer.compose(
                pieces: pieces,
                canvas: display.canvas,
                recipe: MontageRecipe(pieceCount: count, seed: seed,
                                      showCredits: showCredits),
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
    private func loadPieces(
        from pool: SourcePool, count: Int, seed: UInt64, maxPixel: Int,
        includeCredits: Bool = true
    ) async -> [MontagePiece] {
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
            // autoreleasepool：ImageIO 的屬性字典等暫存物件是 autorelease 的，
            // 一輪最多 21 張 × 6 次嘗試，不排掉會堆到整輪合成結束。
            let loaded = autoreleasepool {
                try? ImageLoader.load(
                    local, maxPixel: maxPixel, minimumShortSide: MediaIndexer.minimumShortSide)
            }
            if let image = loaded {
                // 出處要查**原始**的 url，不是物化後的本機副本。
                // 關掉標註時連查都不必查——省掉每片一次的表查詢。
                images.append(MontagePiece(
                    image: image,
                    credit: includeCredits ? credits?.credit(for: url) : nil))
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
