import Foundation
@testable import FoldwallCore

/// 記憶體裡的假檔案系統：可以指定每個目錄的 mtime、讓某個路徑回特定 errno，
/// 並記下實際列過哪些目錄——增量掃描「沒變就不列」只有這樣才驗得到。
///
/// 規則跟真的 POSIX 一樣：在子目錄加檔案只會改子目錄的 mtime，不會往上傳。
final class FakeFileSystem: @unchecked Sendable {
    private struct Dir {
        var modified: TimeInterval
        var entries: [String: DirectoryEntry]
    }

    private let lock = NSLock()
    private var dirs: [String: Dir] = [:]
    private var failures: [String: Int32] = [:]
    /// 允許成功存取 `allowed` 次後，再回這個 errno（掃到一半卸載：根要先 stamp＋list 完）。
    private var failAfterSuccesses: [String: (allowed: Int, code: Int32)] = [:]
    private var successCounts: [String: Int] = [:]
    private var listed: [String] = []

    var listCalls: [String] { lock.withLock { listed } }
    func resetCalls() { lock.withLock { listed = [] } }

    func mkdir(_ path: String, modified: TimeInterval = 100) {
        lock.withLock {
            dirs[path] = Dir(modified: modified, entries: [:])
            linkInParent(path)
        }
    }

    /// 新增或覆寫一個檔案，並把所在目錄的 mtime 設成 `dirModified`。
    /// 原地改檔（不增刪名）時真的檔案系統不會動目錄 mtime——傳原本的值就是在模擬那個情況。
    func addFile(_ path: String, size: Int64 = 1000, modified: TimeInterval = 100,
                 hidden: Bool = false, dirModified: TimeInterval) {
        lock.withLock {
            let (parent, name) = Self.split(path)
            dirs[parent]?.entries[name] = DirectoryEntry(
                name: name, kind: .file, size: size, modified: modified,
                isHidden: hidden, isDataless: false)
            dirs[parent]?.modified = dirModified
            linkInParent(parent)
        }
    }

    /// 刪掉檔案或整棵目錄。
    func remove(_ path: String, dirModified: TimeInterval) {
        lock.withLock {
            let (parent, name) = Self.split(path)
            dirs[parent]?.entries[name] = nil
            dirs = dirs.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
            dirs[parent]?.modified = dirModified
            linkInParent(parent)
        }
    }

    /// 讓這個路徑的 stat 與列目錄都回 `code`；nil＝恢復正常。
    func fail(_ path: String, errno code: Int32?) {
        lock.withLock {
            if let code { failures[path] = code }
            else { failures.removeValue(forKey: path) }
        }
    }

    /// 允許成功存取 `successes` 次（含）後才開始失敗。
    /// 根目錄一次完整驗過＝stamp＋list 兩次；之後再 stat 就模擬整卷卸載。
    func allowSuccessesThenFail(_ path: String, successes: Int, errno code: Int32) {
        lock.withLock { failAfterSuccesses[path] = (successes, code) }
    }

    func read(_ path: String) throws(DirectoryReadError) -> [DirectoryEntry] {
        let result: Result<[DirectoryEntry], DirectoryReadError> = lock.withLock {
            listed.append(path)
            if let error = accessError(path) { return .failure(error) }
            guard let dir = dirs[path] else { return .failure(.unreadable(errno: ENOENT)) }
            markSuccess(path)
            return .success(Array(dir.entries.values))
        }
        return try result.get()
    }

    func stamp(_ path: String) throws(DirectoryReadError) -> TimeInterval {
        let result: Result<TimeInterval, DirectoryReadError> = lock.withLock {
            if let error = accessError(path) { return .failure(error) }
            guard let dir = dirs[path] else { return .failure(.unreadable(errno: ENOENT)) }
            markSuccess(path)
            return .success(dir.modified)
        }
        return try result.get()
    }

    private func accessError(_ path: String) -> DirectoryReadError? {
        if let code = failures[path] { return .unreadable(errno: code) }
        if let rule = failAfterSuccesses[path], (successCounts[path] ?? 0) >= rule.allowed {
            return .unreadable(errno: rule.code)
        }
        return nil
    }

    private func markSuccess(_ path: String) {
        if failAfterSuccesses[path] != nil { successCounts[path, default: 0] += 1 }
    }

    /// `now` 預設遠在所有 mtime 之後，避開「剛改過的目錄一律重列」那條規則；
    /// 要測那條規則時再傳一個貼近 mtime 的值。
    func scanner(now: TimeInterval = 10_000) -> TreeScanner {
        TreeScanner(
            width: 4,
            reader: { path throws(DirectoryReadError) in try self.read(path) },
            stamper: { path throws(DirectoryReadError) in try self.stamp(path) },
            now: { Date(timeIntervalSince1970: now) })
    }

    /// 真的 getattrlistbulk 列父目錄時看得到子目錄的 mtime，這裡同步那一筆。
    private func linkInParent(_ path: String) {
        let (parent, name) = Self.split(path)
        guard let modified = dirs[path]?.modified, dirs[parent] != nil else { return }
        dirs[parent]?.entries[name] = DirectoryEntry(
            name: name, kind: .directory, size: 0, modified: modified,
            isHidden: false, isDataless: false)
    }

    private static func split(_ path: String) -> (String, String) {
        let slash = path.lastIndex(of: "/")!
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }
}
