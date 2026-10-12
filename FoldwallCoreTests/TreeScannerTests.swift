import Foundation
import Testing
@testable import FoldwallCore

@Suite("TreeScanner")
struct TreeScannerTests {

    /// /r/1.jpg、/r/a/2.MOV、/r/a/notes.json、/r/a/deep/3.heic
    private func sample() -> FakeFileSystem {
        let fs = FakeFileSystem()
        fs.mkdir("/r")
        fs.mkdir("/r/a")
        fs.mkdir("/r/a/deep")
        fs.addFile("/r/1.jpg", dirModified: 100)
        fs.addFile("/r/a/2.MOV", dirModified: 100)
        fs.addFile("/r/a/notes.json", dirModified: 100)
        fs.addFile("/r/a/deep/3.heic", dirModified: 100)
        return fs
    }

    private func fullScan(_ fs: FakeFileSystem, roots: [String] = ["/r"]) async -> TreeScan {
        await fs.scanner().scan(previous: DirectoryTree(), roots: roots, scope: nil, relistAll: false)
    }

    @Test("Full scan lists every directory and keeps only media")
    func fullScanKeepsMedia() async {
        let scan = await fullScan(sample())
        #expect(scan.listedDirectories == 3)
        #expect(scan.unreadableRoots.isEmpty)
        let flat = scan.tree.flattened()
        #expect(flat.images == ["/r/1.jpg", "/r/a/deep/3.heic"])
        #expect(flat.videos == ["/r/a/2.MOV"])
    }

    @Test("An unchanged tree is verified with stat alone")
    func unchangedTreeListsNothing() async {
        let fs = sample()
        let first = await fullScan(fs)
        fs.resetCalls()
        let second = await fs.scanner().scan(previous: first.tree, roots: ["/r"], scope: nil, relistAll: false)
        #expect(fs.listCalls.isEmpty)
        #expect(second.checkedDirectories == 3)
        #expect(second.listedDirectories == 0)
        #expect(second.tree == first.tree)
    }

    @Test("A file added deep down is found without relisting its ancestors")
    func deepAdditionListsOnlyThatDirectory() async {
        let fs = sample()
        let first = await fullScan(fs)
        fs.addFile("/r/a/deep/4.png", dirModified: 200)
        fs.resetCalls()
        let second = await fs.scanner().scan(previous: first.tree, roots: ["/r"], scope: nil, relistAll: false)
        #expect(fs.listCalls == ["/r/a/deep"])
        #expect(second.tree.flattened().images.contains("/r/a/deep/4.png"))
    }

    @Test("A deleted subdirectory drops its whole subtree")
    func deletedSubtreeIsDropped() async {
        let fs = sample()
        let first = await fullScan(fs)
        fs.remove("/r/a", dirModified: 200)
        let second = await fs.scanner().scan(previous: first.tree, roots: ["/r"], scope: nil, relistAll: false)
        #expect(second.unreadableRoots.isEmpty)
        #expect(second.tree.flattened().images == ["/r/1.jpg"])
        #expect(second.tree.flattened().videos.isEmpty)
        #expect(second.tree.directories["/r/a/deep"] == nil)
    }

    @Test("A transient error keeps the old subtree and marks the root unreadable")
    func transientErrorKeepsSubtree() async {
        let fs = sample()
        let first = await fullScan(fs)
        fs.fail("/r/a", errno: ETIMEDOUT)
        let second = await fs.scanner().scan(previous: first.tree, roots: ["/r"], scope: nil, relistAll: true)
        #expect(second.unreadableRoots == ["/r"])
        #expect(second.tree.flattened().videos == ["/r/a/2.MOV"])
        #expect(second.tree.flattened().images.contains("/r/a/deep/3.heic"))
    }

    @Test("A missing root is unreadable, not empty")
    func missingRootIsUnreadable() async {
        let fs = sample()
        let first = await fullScan(fs)
        fs.fail("/r", errno: ENOENT)
        let second = await fs.scanner().scan(previous: first.tree, roots: ["/r"], scope: nil, relistAll: false)
        #expect(second.unreadableRoots == ["/r"])
        #expect(second.tree == first.tree)
    }

    @Test("Root device change is treated as unreadable, not deletion")
    func rootDeviceChangeKeepsSubtree() async {
        let fs = sample()
        let first = await fullScan(fs)
        #expect(first.tree.rootDevices["/r"] == 1)
        // 卸載後掛載點還在，但 st_dev 換成宿主／另一顆碟——內容看似被「刪光」其實碟沒了。
        fs.setDevice("/r", 99)
        let second = await fs.scanner().scan(
            previous: first.tree, roots: ["/r"], scope: nil, relistAll: true)
        #expect(second.unreadableRoots == ["/r"])
        #expect(second.tree.flattened().videos == ["/r/a/2.MOV"])
        #expect(second.tree.rootDevices["/r"] == 1, "沿用上一輪的裝置號，下一輪才能繼續辨認")
    }

    @Test("ENOENT on a child after the root vanished mid-scan keeps the subtree")
    func childENOENTWhileRootGoneKeepsSubtree() async {
        let fs = sample()
        let first = await fullScan(fs)
        // 根先 stamp＋list 完，接著讀 /r/a 時整卷卸載：子目錄 ENOENT，再 stat 根也 ENOENT。
        // 若把子目錄 ENOENT 當成「真的刪了」，影片會從池消失且 unreadable 仍是空的。
        fs.allowSuccessesThenFail("/r", successes: 2, errno: ENOENT)
        fs.fail("/r/a", errno: ENOENT)
        let second = await fs.scanner().scan(
            previous: first.tree, roots: ["/r"], scope: nil, relistAll: true)
        #expect(second.unreadableRoots == ["/r"])
        #expect(second.tree.flattened().videos == ["/r/a/2.MOV"])
        #expect(second.tree.flattened().images.contains("/r/a/deep/3.heic"))
    }

    @Test("Directories modified moments ago are relisted next time")
    func recentlyModifiedDirectoryIsRelisted() async {
        let fs = sample()
        // now＝101：每個目錄的 mtime（100）都在 2 秒內，同一秒內可能還有變動沒反映到 mtime
        let first = await fs.scanner(now: 101).scan(previous: DirectoryTree(), roots: ["/r"], scope: nil, relistAll: false)
        #expect(first.tree.directories["/r"]?.modified == DirectoryTree.unknownModified)
        fs.resetCalls()
        _ = await fs.scanner().scan(previous: first.tree, roots: ["/r"], scope: nil, relistAll: false)
        #expect(Set(fs.listCalls) == ["/r", "/r/a", "/r/a/deep"])
    }

    @Test("Scoped scan: timeout keeps the subtree and marks the root unreadable")
    func scopedTimeoutKeepsSubtree() async {
        let fs = sample()
        let first = await fullScan(fs)
        fs.fail("/r/a", errno: ETIMEDOUT)
        let second = await fs.scanner().scan(
            previous: first.tree, roots: ["/r"], scope: ["/r/a"], relistAll: false)
        #expect(second.unreadableRoots == ["/r"])
        #expect(second.tree.flattened().videos == ["/r/a/2.MOV"])
        #expect(second.tree.flattened().images.contains("/r/a/deep/3.heic"))
    }

    @Test("Scoped scan: I/O error keeps the subtree and marks the root unreadable")
    func scopedIOErrorKeepsSubtree() async {
        let fs = sample()
        let first = await fullScan(fs)
        fs.fail("/r/a", errno: EIO)
        let second = await fs.scanner().scan(
            previous: first.tree, roots: ["/r"], scope: ["/r/a"], relistAll: false)
        #expect(second.unreadableRoots == ["/r"])
        #expect(second.tree.flattened().videos == ["/r/a/2.MOV"])
    }

    @Test("Scoped scan: ENOENT while the root is gone keeps the subtree")
    func scopedENOENTWhileRootGoneKeepsSubtree() async {
        let fs = sample()
        let first = await fullScan(fs)
        fs.fail("/r/a", errno: ENOENT)
        fs.fail("/r", errno: ENOENT)   // 再 stat 根也讀不到 → 卸載，不是刪子目錄
        let second = await fs.scanner().scan(
            previous: first.tree, roots: ["/r"], scope: ["/r/a"], relistAll: false)
        #expect(second.unreadableRoots == ["/r"])
        #expect(second.tree.flattened().videos == ["/r/a/2.MOV"])
    }

    @Test("Scope limits checking to the reported subtree")
    func scopeLimitsWork() async {
        let fs = sample()
        let first = await fullScan(fs)
        fs.addFile("/r/outside.jpg", dirModified: 300)       // 範圍外：這輪不該看到
        fs.addFile("/r/a/deep/5.jpg", dirModified: 300)
        fs.resetCalls()
        let second = await fs.scanner().scan(previous: first.tree, roots: ["/r"], scope: ["/r/a/deep"], relistAll: false)
        #expect(fs.listCalls == ["/r/a/deep"])
        let images = second.tree.flattened().images
        #expect(images.contains("/r/a/deep/5.jpg"))
        #expect(!images.contains("/r/outside.jpg"))
        #expect(second.tree.directories.count == 3)
    }

    @Test("A scoped directory is relisted even when its mtime did not change")
    func scopedDirectoryIsAlwaysRelisted() async {
        let fs = sample()
        let first = await fullScan(fs)
        // 原地改檔：名字沒變，目錄 mtime 不動，但大小變了
        fs.addFile("/r/a/deep/3.heic", size: 9999, dirModified: 100)
        let second = await fs.scanner().scan(previous: first.tree, roots: ["/r"], scope: ["/r/a/deep"], relistAll: false)
        #expect(second.tree.directories["/r/a/deep"]?.files.first?.size == 9999)
    }

    @Test("relistAll ignores matching mtimes")
    func relistAllListsEverything() async {
        let fs = sample()
        let first = await fullScan(fs)
        fs.resetCalls()
        let second = await fs.scanner().scan(previous: first.tree, roots: ["/r"], scope: nil, relistAll: true)
        #expect(Set(fs.listCalls) == ["/r", "/r/a", "/r/a/deep"])
        #expect(second.listedDirectories == 3)
    }

    @Test("Nested roots are walked once")
    func nestedRootsAreWalkedOnce() async {
        let fs = sample()
        let scan = await fullScan(fs, roots: ["/r", "/r/a"])
        #expect(fs.listCalls.count == Set(fs.listCalls).count)
        let images = scan.tree.flattened().images
        #expect(images.count == Set(images).count)
    }

    @Test("Hidden entries and packages are skipped")
    func hiddenAndPackagesAreSkipped() async {
        let fs = sample()
        fs.addFile("/r/secret.jpg", hidden: true, dirModified: 100)
        fs.mkdir("/r/.cache")
        fs.addFile("/r/.cache/x.jpg", dirModified: 100)
        fs.mkdir("/r/Lib.photoslibrary")
        fs.addFile("/r/Lib.photoslibrary/y.jpg", dirModified: 100)
        let images = await fullScan(fs).tree.flattened().images
        #expect(images == ["/r/1.jpg", "/r/a/deep/3.heic"])
    }

    @Test("Rebuilding a tree from flat lists keeps every path")
    func treeFromFlatLists() {
        let tree = DirectoryTree(images: ["/r/a/deep/3.heic", "/r/1.jpg"],
                                 videos: ["/r/a/2.MOV"], roots: ["/r"])
        #expect(tree.flattened().images == ["/r/1.jpg", "/r/a/deep/3.heic"])
        #expect(tree.flattened().videos == ["/r/a/2.MOV"])
        #expect(tree.subtree(of: "/r").sorted() == ["/r", "/r/a", "/r/a/deep"])
        #expect(tree.directories.values.allSatisfy { $0.modified == DirectoryTree.unknownModified })
    }
}
