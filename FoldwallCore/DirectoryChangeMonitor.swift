//  DirectoryChangeMonitor.swift
//  本機與外接磁碟上的來源資料夾：用 FSEvents 知道「哪些目錄動了」。
//
//  只拿來**縮小範圍**，不拿來判斷內容：原型實測 FSEvents 回報的目錄可能比實際變動的
//  更上層（在 sub/ 寫檔，回報的是根），而且漏事件時只會說「這棵子樹你自己重掃」。
//  真正的判斷交給 TreeScanner 的 mtime 比對。
//
//  SMB／NFS 不能用：FSEvents 只看得到這台機器自己做的修改，別台電腦往 NAS 丟的照片
//  它不會知道。那些根靠 FolderIndex 定期的增量檢查。

import CoreServices
import Darwin
import Foundation

public final class DirectoryChangeMonitor: @unchecked Sendable {

    public typealias Handler = @Sendable ([String]) -> Void

    /// FSEvents 回報的是 realpath（`/private/var/...`），呼叫端給的根可能是
    /// symlink 形式（`/var/...`）。兩者都記著，回報前轉回呼叫端認得的那個。
    struct Mapping: Sendable, Equatable {
        var real: String
        var logical: String
    }

    /// 回呼拿到的 context。獨立成一個物件並 retain 住：回呼在 FSEvents 的 queue 上跑，
    /// 不能指著一個可能正在 deinit 的 monitor。
    private final class Sink: Sendable {
        let mappings: [Mapping]
        let handler: Handler
        init(mappings: [Mapping], handler: @escaping Handler) {
            self.mappings = mappings
            self.handler = handler
        }
    }

    private let queue = DispatchQueue(label: "app.foldwall.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var sink: Unmanaged<Sink>?

    /// - Parameters:
    ///   - roots: 要盯的根（`DirectoryTree.key(for:)` 的形式）。
    ///   - latency: FSEvents 自己合併事件的時間窗。存一批照片會連發幾百個事件，
    ///     合併成一次回報，FolderIndex 那邊才不會一張照片掃一輪。
    public init(roots: [String], latency: TimeInterval = 5, handler: @escaping Handler) {
        guard !roots.isEmpty else { return }
        let mappings = roots.map { Mapping(real: Self.realPath($0), logical: $0) }
        let sink = Unmanaged.passRetained(Sink(mappings: mappings, handler: handler))
        self.sink = sink

        var context = FSEventStreamContext(
            version: 0, info: sink.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let translated = Set(paths.prefix(count).compactMap {
                DirectoryChangeMonitor.translate($0, mappings: sink.mappings)
            })
            guard !translated.isEmpty else { return }
            sink.handler(translated.sorted())
        }
        // WatchRoot：根本身被改名或刪掉也會回報（FolderIndex 會把它驗成讀不到）
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, mappings.map(\.real) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            sink.release()
            self.sink = nil
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        // 等正在跑的回呼跑完再放掉 sink。
        //
        // **前提：最後一個強參照必須在別條 queue 上釋放（目前只有
        // WallpaperCoordinator 在主執行緒持有）。** 若 deinit 本身跑在
        // `queue` 上，這裡的 `queue.sync {}` 會跟自己死鎖。不要把 monitor
        // 存進會在 FSEvents 回呼裡被清掉的地方。
        queue.sync {}
        sink?.release()
    }

    static func translate(_ eventPath: String, mappings: [Mapping]) -> String? {
        let path = eventPath.count > 1 && eventPath.hasSuffix("/")
            ? String(eventPath.dropLast()) : eventPath
        for mapping in mappings
        where path == mapping.real || path.hasPrefix(mapping.real + "/") {
            return mapping.logical + String(path.dropFirst(mapping.real.count))
        }
        return nil
    }

    /// 不能用 `URL.resolvingSymlinksInPath()`：它會把 `/private/var` 反過來縮成 `/var`。
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
