//  DirectoryTree.swift
//  索引的目錄層：增量重掃的單位是目錄。
//
//  為什麼以目錄為單位：POSIX 目錄的 mtime 只在「直接子項有增刪或改名」時變動。
//  上一輪記下每個目錄的 mtime，這一輪 stat 一次對得上，就知道這個目錄的檔名清單沒變，
//  不必重列——SMB 上一次 stat 是一次往返，重列一個幾千檔的目錄是好幾次。
//  原地改檔不動目錄 mtime，但索引只在乎檔名，那種變動本來就不影響池。

import Foundation

public struct IndexedFile: Sendable, Equatable {
    public var name: String
    public var kind: MediaKind
    /// 列目錄時順手拿到的大小與修改時間。Phase 2 的規則（最近 N 天、太小的圖）會用到。
    public var size: Int64
    public var modified: TimeInterval

    public init(name: String, kind: MediaKind, size: Int64, modified: TimeInterval) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
    }
}

public struct IndexedDirectory: Sendable, Equatable {
    /// 列這個目錄**之前**量到的 mtime。先量後列：列到一半有檔案進來的話，
    /// 下一輪 mtime 一定對不上，不會漏。`DirectoryTree.unknownModified`＝下一輪一定重列。
    public var modified: TimeInterval
    /// 直接子項中的媒體檔（不含子目錄裡的）。
    public var files: [IndexedFile]
    /// 直接子目錄的名稱，已排除隱藏目錄與套件。
    public var subdirectories: [String]

    public init(modified: TimeInterval, files: [IndexedFile], subdirectories: [String]) {
        self.modified = modified
        self.files = files
        self.subdirectories = subdirectories
    }
}

public struct DirectoryTree: Sendable, Equatable {

    /// 不可能是真實 mtime 的值：比對一定失敗，下一輪一定重列。
    public static let unknownModified: TimeInterval = -1

    /// 鍵是目錄的絕對路徑，不帶結尾斜線（見 `key(for:)`）。
    public var directories: [String: IndexedDirectory]
    /// 每個根上一輪是否為掛載點（根的 `st_dev` ≠ 父目錄的 `st_dev`）。
    /// 只有「上次是、這次不是」才當成卸載後的空掛載點；重新掛載裝置號會變但仍是掛載點。
    /// 舊落地檔沒有這個欄位時是空的；缺值不得當成掛載點降級。
    public var rootIsMountPoint: [String: Bool]

    public init(directories: [String: IndexedDirectory] = [:],
                rootIsMountPoint: [String: Bool] = [:]) {
        self.directories = directories
        self.rootIsMountPoint = rootIsMountPoint
    }

    public var isEmpty: Bool { directories.isEmpty }

    /// 這個根底下（含自己）是否還記著媒體檔或子目錄。
    public func hasContent(under root: String) -> Bool {
        subtree(of: root).contains { key in
            guard let directory = directories[key] else { return false }
            return !directory.files.isEmpty || !directory.subdirectories.isEmpty
        }
    }

    /// 根目錄路徑的標準形：standardized、不帶結尾斜線。
    ///
    /// 要自己剝結尾斜線：`path(percentEncoded:)` 會保留它，`/a/` 與 `/a` 會被當成兩個根。
    public static func key(for url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    public static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    /// `path` 底下（含自己）所有記錄在樹裡的目錄。沿 `subdirectories` 走，不掃整個字典。
    public func subtree(of path: String) -> [String] {
        var found: [String] = []
        var stack = [path]
        while let next = stack.popLast() {
            guard let directory = directories[next] else { continue }
            found.append(next)
            stack.append(contentsOf: directory.subdirectories.map { Self.join(next, $0) })
        }
        return found
    }

    /// 把 `other` 裡 `path` 這棵子樹原封不動搬過來（讀不到、或不在這輪檢查範圍內）。
    public mutating func copySubtree(of path: String, from other: DirectoryTree) {
        for key in other.subtree(of: path) {
            directories[key] = other.directories[key]
        }
        if let flag = other.rootIsMountPoint[path] {
            rootIsMountPoint[path] = flag
        }
    }

    /// 只留下屬於這些根的目錄（使用者移除了資料夾）。
    public mutating func removeAll(outside roots: [String]) {
        let matcher = RootMatcher(roots.map { URL(filePath: $0, directoryHint: .isDirectory) })
        directories = directories.filter { matcher.root(ofPath: $0.key) != nil }
        rootIsMountPoint = rootIsMountPoint.filter { matcher.root(ofPath: $0.key) != nil }
    }

    /// 攤平成 `FolderIndex.Snapshot` 用的路徑清單，排序過——同一 seed 的蒙太奇要可重現。
    ///
    /// 樹是字典，同一個目錄只會出現一次，所以巢狀的根也不會產生重複路徑。
    public func flattened() -> (images: [String], videos: [String]) {
        var images: [String] = []
        var videos: [String] = []
        for (path, directory) in directories {
            for file in directory.files {
                let full = Self.join(path, file.name)
                switch file.kind {
                case .image: images.append(full)
                case .video: videos.append(full)
                }
            }
        }
        images.sort()
        videos.sort()
        return (images, videos)
    }

    /// 從平面路徑清單重建（v1 落地檔、只會全量掃描的 `MediaIndexing`）。
    ///
    /// 沒有 mtime 可用，每個目錄都標成未知：下一輪增量掃描一定全部重列，
    /// 等於一次全量——但池在那之前是滿的，離線根的檔案也還在樹裡。
    public init(images: [String], videos: [String], roots: [String]) {
        let rootKeys = roots.map { Self.key(for: URL(filePath: $0, directoryHint: .isDirectory)) }
        let matcher = RootMatcher(rootKeys.map { URL(filePath: $0, directoryHint: .isDirectory) })
        var directories: [String: IndexedDirectory] = [:]
        var children: [String: Set<String>] = [:]

        func ensure(_ path: String) {
            if directories[path] == nil {
                directories[path] = IndexedDirectory(
                    modified: Self.unknownModified, files: [], subdirectories: [])
            }
        }

        func add(_ path: String, kind: MediaKind) {
            guard let rootURL = matcher.root(ofPath: path),
                  let slash = path.lastIndex(of: "/") else { return }
            let root = Self.key(for: rootURL)
            let parent = slash == path.startIndex ? "/" : String(path[..<slash])
            ensure(parent)
            directories[parent]?.files.append(IndexedFile(
                name: String(path[path.index(after: slash)...]), kind: kind, size: 0, modified: 0))
            // 往上把每一層接到父目錄的 subdirectories，接過的那層以上一定也接過了
            var child = parent
            while child != root, child.count > root.count, let cut = child.lastIndex(of: "/") {
                let up = String(child[..<cut])
                let name = String(child[child.index(after: cut)...])
                guard children[up, default: []].insert(name).inserted else { break }
                ensure(up)
                child = up
            }
        }

        for root in rootKeys { ensure(root) }
        for path in images { add(path, kind: .image) }
        for path in videos { add(path, kind: .video) }
        for (path, names) in children { directories[path]?.subdirectories = names.sorted() }
        self.init(directories: directories)
    }
}
