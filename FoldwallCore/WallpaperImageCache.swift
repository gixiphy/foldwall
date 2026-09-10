//  WallpaperImageCache.swift
//  幫系統的圖片桌布 extension 收拾它替我們產生的快取。
//
//  為什麼需要它：每輪合成都用**新檔名**呼叫 `setDesktopImageURL`（同名覆寫不會刷新，
//  見 StillPipeline.write），系統的 `com.apple.wallpaper.extension.image` 收到之後會把
//  那張 JPEG 解成**整塊螢幕像素大小的未壓縮 BMP** 存進自己的快取目錄——5120×1440
//  一張 22 MB、2880×1800 一張 15.5 MB——而且從不清。我們自己的 JPEG 只留兩代
//  （`StillPipeline.generationsKept`），系統那份卻每輪都長 37 MB：照 5 分鐘一輪是
//  一天 10 GB，啟動後那幾輪連跑更快。實測 7 分鐘就堆了 309 MB。
//
//  做法：每輪合成後，把**我們剛寫過的那幾塊螢幕解析度**的 BMP 按修改時間排序，
//  留跟 JPEG 一樣的代數，其餘刪掉。那個目錄是 `~/Library/Caches` 性質的快取，
//  系統空間不足時本來就會被清；extension 找不到快取會從來源重畫，不會黑屏。
//
//  **只碰自己寫過的解析度、只碰 .bmp、只碰檔名長得像它產物的檔。** 其他解析度
//  （extension 引擎播影片、或使用者自己選圖的螢幕）一張都不動。
//
//  檔名格式（實測）：`<64 hex>-<寬>-<高>-<n>-<16 hex>.bmp`。前面那段 hash 不是
//  JPEG 的內容也不是路徑（兩種都試過），是它自己的設定 blob；後面 16 hex 是
//  CFAbsoluteTime 的 IEEE-754 位元組。我們不解它，寬高與修改時間就夠了。

import CoreGraphics
import Foundation

public struct WallpaperImageCache: Sendable {

    public struct Outcome: Sendable, Equatable {
        public var deletedCount = 0
        public var deletedBytes: Int64 = 0
        public init(deletedCount: Int = 0, deletedBytes: Int64 = 0) {
            self.deletedCount = deletedCount
            self.deletedBytes = deletedBytes
        }
    }

    /// 每塊螢幕留幾代。跟 `StillPipeline.generationsKept` 同一個數，理由也一樣：
    /// 系統可能仍持有上一輪那張（其他 Space 就停在它上面）。
    public static let generationsKept = StillPipeline.generationsKept

    /// 剛寫進去、還沒滿這個秒數的檔不刪。extension 是在我們 `setDesktopImageURL`
    /// 之後才**非同步**產這張 BMP（實測慢 10 秒上下），別跟它的寫入撞在一起。
    ///
    /// 這也表示每輪合成結束當下清的是「上一輪以前」的，這一輪那張要下一輪才輪到——
    /// 穩態每塊螢幕會停在 `generationsKept + 1` 張，不是無限。
    public static let grace: TimeInterval = 60

    /// 系統 extension 的快取目錄；macOS 14–26 都在這裡。
    public static func defaultDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appending(path: """
            Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/\
            com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.image
            """)
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func standard() -> WallpaperImageCache {
        WallpaperImageCache(directory: defaultDirectory())
    }

    // MARK: - 檔名

    /// 一張 extension 產物的身分：像素寬高。
    struct Entry: Equatable {
        var url: URL
        var width: Int
        var height: Int
        var modified: Date
        var bytes: Int64
    }

    /// nil＝不是 extension 的產物（.DS_Store、別的格式、我們不認得的命名）。
    ///
    /// 手拆而不用 Regex：格式就五段，拆完逐段驗比正則好讀，也不用管 `Regex`
    /// 在 strict concurrency 下能不能當 static let。
    static func dimensions(ofName name: String) -> (width: Int, height: Int)? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              Self.isHex(parts[0], count: 64),
              let width = Int(parts[1]), width > 0,
              let height = Int(parts[2]), height > 0,
              Int(parts[3]) != nil,
              parts[4].hasSuffix(".bmp"),
              Self.isHex(parts[4].dropLast(4), count: 16)
        else { return nil }
        return (width, height)
    }

    private static func isHex(_ text: Substring, count: Int) -> Bool {
        text.count == count && text.allSatisfy(\.isHexDigit)
    }

    // MARK: - 清理

    /// 把 `displays` 這幾塊螢幕解析度的舊 BMP 清到只剩 `generationsKept` 代。
    ///
    /// - Parameter displays: **這一輪真的寫了桌布**的螢幕。跳過的（影片螢幕）不要傳——
    ///   那塊的快取不是我們產的。兩塊同解析度的螢幕會共用一組，留的張數跟著乘。
    /// - Returns: 刪了幾張、幾位元組；目錄不存在或讀不到就是全零，不丟錯——
    ///   這是順手收拾，不能讓合成那條路因它失敗。
    @discardableResult
    public func prune(
        displays: [DisplayTarget],
        keepGenerations: Int = generationsKept,
        now: Date = .now
    ) -> Outcome {
        var outcome = Outcome()
        guard !displays.isEmpty else { return outcome }

        // 同解析度的螢幕併成一組：extension 的快取只認寬高，分不出是哪一塊。
        var displaysPerSize: [String: Int] = [:]
        for display in displays {
            displaysPerSize[Self.sizeKey(display.canvas), default: 0] += 1
        }

        let entries = Self.entries(in: directory)
        let grouped = Dictionary(grouping: entries) { Self.sizeKey(width: $0.width, height: $0.height) }

        let fm = FileManager.default
        for (key, count) in displaysPerSize {
            guard let group = grouped[key] else { continue }
            let keep = max(1, count * max(1, keepGenerations))
            let sorted = group.sorted { $0.modified > $1.modified }
            for entry in sorted.dropFirst(keep) {
                // 剛落地的不動：extension 可能還在寫它
                guard now.timeIntervalSince(entry.modified) >= Self.grace else { continue }
                do {
                    try fm.removeItem(at: entry.url)
                    outcome.deletedCount += 1
                    outcome.deletedBytes += entry.bytes
                } catch {
                    continue   // 個別檔刪不掉（權限、剛被它自己移走）就留著，下輪再試
                }
            }
        }
        return outcome
    }

    /// 目錄裡目前的 extension 產物總量，給診斷與設定頁看。
    public func measure() -> (count: Int, bytes: Int64) {
        let entries = Self.entries(in: directory)
        return (entries.count, entries.reduce(0) { $0 + $1.bytes })
    }

    static func entries(in directory: URL) -> [Entry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        else { return [] }
        return urls.compactMap { url in
            guard let size = dimensions(ofName: url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { return nil }
            return Entry(url: url, width: size.width, height: size.height,
                         modified: modified, bytes: Int64(values.fileSize ?? 0))
        }
    }

    private static func sizeKey(_ canvas: CGSize) -> String {
        sizeKey(width: Int(canvas.width.rounded()), height: Int(canvas.height.rounded()))
    }

    private static func sizeKey(width: Int, height: Int) -> String {
        "\(width)x\(height)"
    }
}
