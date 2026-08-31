//  VideoDownload.swift
//  用**使用者自己安裝的** yt-dlp 從網址取得影片檔。
//
//  界線講清楚：Foldwall **不實作**任何串流解析或簽章繞過——那是規避技術保護
//  措施。這裡只負責找到使用者機器上既有的工具、組出參數、把結果收進影片來源。
//  抽取那一段由那個工具負責，也由使用者自己決定要對哪個站用。
//
//  順帶的好處：yt-dlp 支援上千個站，不必為每一個寫解析器。

import Foundation

public enum VideoDownloadTool {

    public static let executableName = "yt-dlp"

    /// GUI app **不繼承 shell 的 PATH**。從 LaunchServices 啟動時
    /// `/opt/homebrew/bin` 根本不在環境變數裡，直接呼叫名字必然失敗。
    /// 所以要自己找常見安裝位置。
    public static let searchPaths = [
        "/opt/homebrew/bin",      // Homebrew（Apple Silicon）
        "/usr/local/bin",         // Homebrew（Intel）／手動安裝
        "/opt/local/bin",         // MacPorts
        "/usr/bin",
    ]

    /// - Parameter home: 使用者家目錄，用來找 `~/.local/bin`（pipx／pip --user）。
    public static func locate(
        home: URL = URL.homeDirectory,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let candidates = searchPaths.map { "\($0)/\(executableName)" }
            + [home.appending(path: ".local/bin/\(executableName)").path]
        return candidates.first(where: exists).map { URL(filePath: $0) }
    }

    /// ffmpeg 在哪。分離軌要靠它 remux 成 mp4，退回單一檔案那條路也要它合併。
    ///
    /// 找法跟 yt-dlp 一樣（GUI app 不繼承 shell 的 PATH），常見的安裝位置也一樣。
    public static func locateFFmpeg(
        home: URL = URL.homeDirectory,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let candidates = searchPaths.map { "\($0)/ffmpeg" }
            + [home.appending(path: ".local/bin/ffmpeg").path]
        return candidates.first(where: exists).map { URL(filePath: $0) }
    }

    /// - Parameters:
    ///   - destination: 存放目錄。
    ///   - ffmpeg: 找得到 ffmpeg 就傳它，會多要「分離軌」那條路。
    ///   - quality: 畫質上限，**由使用者決定**（見 `VideoDownloadQuality`）。
    ///   - cookies: 要不要借瀏覽器的登入狀態（見 `VideoCookieSource`）。
    /// - Returns: 傳給 yt-dlp 的參數。
    ///
    /// **為什麼要分兩種格式選擇**：原本刻意只取單一檔案（不用 `bv+ba` 那種要
    /// 合併的），理由是合併需要 ffmpeg 而使用者不見得裝了。代價是 2026 年的
    /// YouTube 幾乎不再提供 muxed 格式——實測整張格式表只有 DASH 的分離軌，
    /// 於是每一支都以 `Requested format is not available` 收場，片單一支也抓不下來。
    ///
    /// 所以：有 ffmpeg 就走分離軌，沒有才退回單一檔案（對還提供 muxed 的站仍然有效）。
    /// 判斷放在呼叫端，這裡只負責照著組參數。
    ///
    /// **不要音訊軌。** `DesktopVideoEngine` 一開場就 `player.isMuted = true`，
    /// 桌布不出聲，音訊抓下來只是躺在檔案裡佔空間——實測整個快取有 8.3% 是這樣來的，
    /// 而位元率被壓爛的那幾支裡音訊佔到一半。Pexels 的影片本來就沒有音軌、
    /// 一直播得好好的，所以「沒有音軌的 mp4」這條路是驗證過的，不是賭的。
    ///
    /// **`-S "res,br"` 是畫質的關鍵，不是可有可無的調味。** yt-dlp 預設的排序鍵
    /// 順序是 `…res, fps, hdr, vcodec, …, br, …`——`vcodec` 排在 `br` **前面**，
    /// 而預設的 codec 偏好是 av01 > vp9 > h264。YouTube 的 AV1 階梯位元率壓得最狠，
    /// 於是「yt-dlp 最偏好的 codec」剛好就是「畫質最差的那條流」。實測同一支
    /// 1080p60，量的是**抓下來的檔案**不是格式表上的數字：預設拿到 av01 557 kbps，
    /// 加上這個排序拿到 avc1 1206 kbps。另一支上這個排序會選到 YouTube 標成
    /// Premium 的那條，實測 2461 kbps 對 1471 kbps。
    /// 附帶的好處是 h264 在 Apple Silicon 上有專用硬體解碼器，比 AV1 省電。
    ///
    /// **格式表上的 `tbr`／`vbr` 不能當真，HLS 那幾條尤其。** 實測同一支影片：
    /// 格式 270（m3u8）宣稱 4634 kbps，抓下來 1472 kbps；它的 https 雙胞胎 137
    /// 宣稱 1424 kbps，抓下來 1471 kbps——**同一份編碼，m3u8 那條的宣稱值灌了三倍**
    /// （manifest 報的是峰值頻寬，不是平均）。https 那邊的數字才是準的。
    ///
    /// 所以排序照樣用 `br`（它仍然會把 av01 那條爛的排到後面，而且真的更好的
    /// Premium 流只有 m3u8 有），但**任何要拿給使用者看的位元率都不能從這裡取**——
    /// 那會變成「介面說 4596、實際 1206」。要報就報解析度與編碼，見 `cookieCheckArguments`。
    public static func arguments(
        url: String, destination: URL, ffmpeg: URL? = nil,
        quality: VideoDownloadQuality = .default, cookies: VideoCookieSource = .none
    ) -> [String] {
        let cap = quality.heightFilter
        // 沒有 ffmpeg 就沒得 remux，只能收單一檔案——連音訊也甩不掉。
        let singleFile = "b\(cap)[ext=mp4]/b[ext=mp4]/b\(cap)/b"
        var arguments = [
            "--no-playlist",              // 貼到播放清單網址時只抓那一支
            "--no-part",                  // 不留 .part 半成品在來源目錄裡
            "--no-progress",
            "--newline",
        ]
        arguments += cookies.arguments
        if let ffmpeg {
            arguments += [
                // 同解析度挑位元率最高的那條流。理由見上面那段長註解。
                "-S", "res,br",
                "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
                // 只要視訊軌就不會有「合併」這一步，`--merge-output-format` 也就不生效。
                // 但 `-S "res,br"` 有時會挑到 webm 容器的 vp9，而 **AVFoundation 不
                // demux webm**——那會變成抓下來卻整支播不了。remux 補上這個保證。
                "--remux-video", "mp4",
                "-f", "bv*\(cap)/\(singleFile)",
            ]
        } else {
            arguments += ["-f", singleFile]
        }
        arguments += [
            "-o", destination.appending(path: "%(title).80B [%(id)s].%(ext)s").path,
            url,
        ]
        return arguments
    }

    // MARK: - 版本

    /// 問工具版本的參數。
    public static let versionArguments = ["--version"]

    /// 解析版號。
    ///
    /// yt-dlp 用**日期版號**：`2026.08.19`，nightly 多接一段
    /// （`2026.08.19.232712`），GitHub 的 tag 也是同一套。Homebrew 會把前導零
    /// 去掉（`2026.8.19`），所以比字串沒有用，要比數字。
    /// 解不出來就回 nil——**寧可不提醒，也不要亂猜版本**。
    public static func parseVersion(_ text: String) -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let numbers = parts.prefix(3).compactMap { Int($0) }
        guard numbers.count == 3, numbers[0] >= 2000,
              (1...12).contains(numbers[1]), (1...31).contains(numbers[2])
        else { return nil }
        return numbers
    }

    /// 問 GitHub 最新的 release 是哪一版。
    ///
    /// 為什麼是「有沒有新版」而不是「幾天沒更新」：後者是猜的。一個十天前才
    /// 更新過的人如果已經是最新版，叫他去更新就是錯的建議——他照做也不會好，
    /// 還會以為問題處理掉了。直接問上游最新是幾版，答案沒有模糊空間。
    public static func latestReleaseRequest() -> URLRequest {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub 對沒帶 User-Agent 的請求回 403。
        request.setValue("Foldwall", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return request
    }

    /// 從 release JSON 撈出 tag。
    public static func parseLatestRelease(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String, !tag.isEmpty
        else { return nil }
        return tag
    }

    /// 裝的這版落後上游了嗎。
    ///
    /// 任何一邊解不出版號就回 `false`：查不到不是「有問題」，不確定的時候
    /// 指著使用者的工具說它舊最糟。
    public static func isOutdated(installed: String?, latest: String?) -> Bool {
        guard let installed, let latest,
              let mine = parseVersion(installed), let theirs = parseVersion(latest)
        else { return false }
        for (a, b) in zip(mine, theirs) where a != b { return a < b }
        return false
    }

    /// 網址看起來合理嗎。擋掉明顯的手滑，真正能不能抓由工具決定。
    public static func isPlausible(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed), let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme), parsed.host?.isEmpty == false
        else { return false }
        return true
    }
}

/// 下載畫質的上限。**由使用者決定，不寫死。**
///
/// 0.6.8 以前這裡是一個寫死的 `maximumHeight = 1080`，理由是「桌布不需要 4K：
/// 檔案大好幾倍、解碼更吃電」。那個理由本身沒錯，錯在替使用者做了決定——
/// 「夠用」是多少只有他知道：27 吋 5K 上看得出來的糊，13 吋上看不出來。
/// 所以這裡只提供選項與各自的代價。
public enum VideoDownloadQuality: String, CaseIterable, Codable, Sendable, Identifiable {

    case p720, p1080, p1440, p2160, best

    /// 沒設定過就是這個。跟 0.6.8 以前寫死的值一樣，升上來的人畫質不會突然變。
    public static let `default` = VideoDownloadQuality.p1080

    public var id: String { rawValue }

    /// `nil` ＝不設上限，站上有什麼就拿什麼。
    public var maximumHeight: Int? {
        switch self {
        case .p720: 720
        case .p1080: 1080
        case .p1440: 1440
        case .p2160: 2160
        case .best: nil
        }
    }

    /// 接在 yt-dlp 格式選擇器後面的高度過濾片段。不設上限就是空字串，
    /// 讓 `bv*\(cap)` 自然變回 `bv*`。
    public var heightFilter: String {
        maximumHeight.map { "[height<=\($0)]" } ?? ""
    }

    /// rawValue 不兼差當顯示文字（翻譯之後等於換一組 id，Picker 的 selection 會對不上）。
    ///
    /// 解析度是數字不是詞，**刻意不進字串表**：塞進去只會多幾條「英文＝中文」
    /// 的假翻譯，還要每次漏翻檢查都被唸一次。
    public var displayName: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .p2160: "4K"
        case .best: String(localized: "不設上限", bundle: .foldwallCore)
        }
    }

    /// 選這個要付什麼代價。數字是實測值：一段 51 分鐘的快取，只留視訊軌。
    public var detail: String {
        switch self {
        case .p720: String(localized: "最省空間。外接大螢幕上看得出來。", bundle: .foldwallCore)
        case .p1080: String(localized: "多數螢幕夠用。一小時約 1 GB。", bundle: .foldwallCore)
        case .p1440: String(localized: "27 吋以上才看得出跟 1080p 的差別。", bundle: .foldwallCore)
        case .p2160: String(localized: "檔案大好幾倍，解碼也更吃電。", bundle: .foldwallCore)
        case .best: String(localized: "站上有多好就拿多好。快取會很快滿。", bundle: .foldwallCore)
        }
    }
}

/// 要不要借某個瀏覽器的登入狀態（cookie）給 yt-dlp。
///
/// **為什麼需要這個**：很多站把最好的那幾條流留給登入的人。實測 YouTube 同一支
/// 1080p60，沒登入拿得到的最高是 1209 kbps，登入之後多出 4596 kbps 那條。
/// 「畫質怎麼調都還是糊」有時候不是參數的問題，是根本沒資格拿到好的那條。
///
/// **界線**：Foldwall 自己不碰 cookie，也不複製、不儲存、不外傳任何一個位元組——
/// 只是把「去哪個瀏覽器拿」這個選擇傳給 yt-dlp，讀取與使用都發生在 yt-dlp 行程裡，
/// 全程在這台機器上。所以這裡存的只有瀏覽器名字。
public enum VideoCookieSource: String, CaseIterable, Codable, Sendable, Identifiable {

    case none, safari, chrome, brave, edge, firefox, chromium, vivaldi, opera

    public var id: String { rawValue }

    /// 傳給 yt-dlp 的參數。rawValue 就是 yt-dlp 認得的瀏覽器名。
    public var arguments: [String] {
        self == .none ? [] : ["--cookies-from-browser", rawValue]
    }

    /// 瀏覽器名字是專有名詞，**刻意不進字串表**（理由同 `VideoDownloadQuality`）。
    /// 只有「不使用」那條是真的要翻。
    public var displayName: String {
        switch self {
        case .none: String(localized: "不使用（未登入）", bundle: .foldwallCore)
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Edge"
        case .firefox: "Firefox"
        case .chromium: "Chromium"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        }
    }

    /// Safari 的 cookie 檔在 TCC 保護的位置，讀它要「完全取用磁碟」。
    ///
    /// 而且授權對象是 **Foldwall.app**，不是 yt-dlp：子行程的 TCC 判定歸屬於
    /// 負責的行程，也就是把它叫起來的那個 app。
    public var needsFullDiskAccess: Bool { self == .safari }

    /// Chromium 系把 cookie 加密，金鑰放在鑰匙串（`… Safe Storage`），
    /// 第一次讀會跳一次鑰匙串授權對話框。
    public var needsKeychain: Bool {
        switch self {
        case .chrome, .brave, .edge, .chromium, .vivaldi, .opera: true
        case .none, .safari, .firefox: false
        }
    }

    /// 這台機器上這個瀏覽器的設定檔目錄。**只用來判斷「有沒有裝」，不判斷有沒有授權。**
    ///
    /// Safari 回 nil：它隨 macOS 一起來，一定在；而它的 cookie 檔在 TCC 底下，
    /// 沒授權時連「存不存在」都問不出來，拿存在與否當安裝與否會反過來說「沒裝 Safari」。
    public func profileDirectory(home: URL = URL.homeDirectory) -> URL? {
        let support = home.appending(path: "Library/Application Support")
        return switch self {
        case .none, .safari: nil
        case .chrome: support.appending(path: "Google/Chrome")
        case .brave: support.appending(path: "BraveSoftware/Brave-Browser")
        case .edge: support.appending(path: "Microsoft Edge")
        case .firefox: support.appending(path: "Firefox")
        case .chromium: support.appending(path: "Chromium")
        case .vivaldi: support.appending(path: "Vivaldi")
        case .opera: support.appending(path: "com.operasoftware.Opera")
        }
    }

    /// 這台機器上看起來裝了嗎。查不到設定檔目錄的（Safari）一律當有。
    public func isInstalled(
        home: URL = URL.homeDirectory,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard self != .none else { return true }
        guard let directory = profileDirectory(home: home) else { return true }
        return exists(directory.path(percentEncoded: false))
    }
}

/// 借登入狀態這件事，實際跑一次的結果。
///
/// **為什麼要真的跑一次**：能不能讀到 cookie 牽涉 TCC、鑰匙串、瀏覽器版本，
/// 從外面用「檔案在不在」猜是猜不準的——Safari 那個檔沒授權時連存不存在都問不出來。
/// 直接跑一次 yt-dlp，答案沒有模糊空間。
public enum VideoCookieCheck: Sendable, Equatable {
    /// 讀到了。`count` 是 yt-dlp 說它讀到幾個；`stream` 是這支影片在目前設定下
    /// 會拿到的那條流（解析度與編碼），用來讓使用者看見授權到底換到了什麼。
    ///
    /// **刻意不是位元率**：格式表上那個數字對 HLS 是灌水的，見 `arguments` 的註解。
    case ok(count: Int?, stream: String?)
    /// Safari：要去系統設定給 Foldwall「完全取用磁碟」。
    case needsFullDiskAccess
    /// Chromium 系：鑰匙串那關沒過。
    case needsKeychain
    /// 這台機器上找不到這個瀏覽器的 cookie。
    case browserNotFound
    /// 其他。原文帶出來，不要自己編一句。
    case failed(String)
}

extension VideoDownloadTool {

    /// yt-dlp 官方那支長年不變的測試影片。使用者還沒有任何片單時拿它當靶。
    public static let cookieProbeURL = "https://www.youtube.com/watch?v=BaW_jenozKc"

    /// 借登入狀態測試用的參數：**只問不下載**（`--simulate`）。
    ///
    /// 帶上 `quality` 與 `-S "res,br"` 是刻意的：要問的是「授權之後，**照你現在的
    /// 設定**會拿到哪一條流」，不是「這個站最好的是哪條」。
    ///
    /// **印解析度與編碼，不印位元率。** 格式表上的 `vbr` 對 HLS 的那幾條是灌水的
    /// （實測宣稱 4634、實際 1472，見 `arguments` 的註解），而排序又常常剛好選中
    /// 那幾條。印出來就是拿一個假數字去騙使用者，比不印還糟。
    public static func cookieCheckArguments(
        url: String, quality: VideoDownloadQuality = .default,
        cookies: VideoCookieSource
    ) -> [String] {
        let cap = quality.heightFilter
        return cookies.arguments + [
            "--simulate",
            "--no-playlist",
            "--ignore-config",
            // 網路卡住的話按鈕會一直轉。測試是使用者按下去等答案的動作，
            // 寧可十五秒後說「連不上」，也不要沒有盡頭地轉。
            "--socket-timeout", "15",
            "-S", "res,br",
            "-f", "bv*\(cap)/b\(cap)/b",
            "--print", "\(probeMarker) %(height)sp %(vcodec)s",
            url,
        ]
    }

    /// 印出來的那行前綴。yt-dlp 的輸出裡還有別的東西，要認得出自己那行。
    static let probeMarker = "foldwall-probe"

    /// 看 yt-dlp 到底怎麼了。
    ///
    /// 判斷順序有意義：**先認得出「要授權」的那幾種**，剩下的才報原文。
    /// 反過來的話，一句「ERROR: …」就把「去開完全取用磁碟」這個唯一的解法蓋掉了。
    public static func explainCookieCheck(_ output: String, succeeded: Bool) -> VideoCookieCheck {
        let lower = output.lowercased()

        // TCC 擋下來的樣子有好幾種寫法，全都指向同一個解法。
        if lower.contains("operation not permitted")
            || lower.contains("permissionerror")
            || lower.contains("could not find safari cookies database")
            || (lower.contains("safari") && lower.contains("permission denied")) {
            return .needsFullDiskAccess
        }
        if lower.contains("safe storage")
            || lower.contains("failed to decrypt")
            || lower.contains("unable to decrypt")
            || lower.contains("keyring") {
            return .needsKeychain
        }
        if lower.contains("cookies database") || lower.contains("could not find cookies") {
            return .browserNotFound
        }

        guard succeeded else { return .failed(explain(output)) }
        return .ok(count: extractedCookieCount(output), stream: probedStream(output))
    }

    /// `Extracted 1234 cookies from chrome` 裡的那個數字。
    static func extractedCookieCount(_ output: String) -> Int? {
        for line in output.split(separator: "\n") where line.contains("Extracted") {
            let parts = line.split(separator: " ")
            guard let index = parts.firstIndex(of: "Extracted"), index + 1 < parts.count,
                  let count = Int(parts[index + 1])
            else { continue }
            return count
        }
        return nil
    }

    /// `--print` 那行印出來的「會拿到哪一條流」，例如 `1080p avc1.64002A`。
    static func probedStream(_ output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix(probeMarker) {
            let rest = line.dropFirst(probeMarker.count)
                .trimmingCharacters(in: .whitespaces)
            // yt-dlp 查不到某個欄位時印的是字面上的 NA，那不值得拿給使用者看。
            guard !rest.isEmpty, !rest.contains("NA") else { return nil }
            return rest
        }
        return nil
    }

    /// 錯誤原文裡最有用的那一行。跟 PlaylistService 的同名邏輯一樣：
    /// 有 ERROR 就取 ERROR，沒有就取最後一行。
    static func explain(_ text: String) -> String {
        let lines = text.split(separator: "\n")
        guard let line = lines.last(where: { $0.contains("ERROR") }) ?? lines.last else {
            return String(localized: "測試失敗", bundle: .foldwallCore)
        }
        if let range = line.range(of: "ERROR: ") { return String(line[range.upperBound...]) }
        return String(line)
    }
}

public enum VideoDownloadState: Sendable, Equatable {
    case idle
    case running
    case finished(name: String)
    case failed(reason: String)

    public var summary: String {
        switch self {
        case .idle: ""
        case .running: String(localized: "下載中…", bundle: .foldwallCore)
        case .finished(let name): String(localized: "完成：\(name)", bundle: .foldwallCore)
        case .failed(let reason): reason
        }
    }
}
