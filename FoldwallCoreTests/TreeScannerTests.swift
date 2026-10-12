import Foundation
import Testing
@testable import FoldwallCore

@Suite("TreeScanner")
struct TreeScannerTests {

    /// /r/1.jpg、/r/a/2.MOV、/r/a/notes.json、/r/a/deep/3.heic
    /// - `rootDevice` 與父目錄 `/`（裝置 1）不同時＝掛載點。
    private func sample(rootDevice: UInt64 = 1) -> FakeFileSystem {
        let fs = FakeFileSystem()
        fs.mkdir("/", device: 1)
        fs.mkdir("/r", device: rootDevice)
        fs.mkdir("/r/a", device: rootDevice)
        fs.mkdir("/r/a/deep", device: rootDevice)
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

    @Test("Root still present: a real subdirectory deletion drops the subtree and stays complete")
    func realSubdirectoryDeletionDropsSubtreeAndStaysComplete() async {
        // 專門鎖住這個語意：根還在、仍是／仍不是掛載點、只是子目錄沒了 → 必須當成刪除，
        // 不能被「空掛載點」那條規則誤傷（否則使用者刪資料夾永遠清不掉池裡的片）。
        let fs = sample()
        let first = await fullScan(fs)
        #expect(first.tree.rootIsMountPoint["/r"] == false)
        fs.remove("/r/a", dirModified: 200)
        let second = await fs.scanner().scan(
            previous: first.tree, roots: ["/r"], scope: nil, relistAll: false)
        #expect(second.unreadableRoots.isEmpty, "清單仍可標完整")
        #expect(second.tree.flattened().videos.isEmpty)
        #expect(second.tree.flattened().images == ["/r/1.jpg"])
        #expect(second.tree.directories["/r/a"] == nil)
        #expect(second.tree.directories["/r/a/deep"] == nil)
        #expect(second.tree.rootIsMountPoint["/r"] == false)
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

    @Test("A first scan of an empty root is complete, not unreadable")
    func firstScanOfEmptyRootIsComplete() async {
        let fs = FakeFileSystem()
        fs.mkdir("/", device: 1)
        fs.mkdir("/empty", device: 1)
        let scan = await fs.scanner().scan(
            previous: DirectoryTree(), roots: ["/empty"], scope: nil, relistAll: false)
        #expect(scan.unreadableRoots.isEmpty)
        #expect(scan.tree.directories["/empty"] != nil)
        #expect(scan.tree.rootIsMountPoint["/empty"] == false)
        #expect(scan.tree.flattened().images.isEmpty)
        #expect(scan.tree.flattened().videos.isEmpty)
    }

    @Test("Missing rootIsMountPoint from an old index does not false-vacate")
    func missingRootIsMountPointDoesNotFalseVacate() async {
        let fs = sample(rootDevice: 2)
        let first = await fullScan(fs)
        // 升級後的樹：有內容、還沒記掛載點旗標。缺欄位不得當成「掛載點變了」。
        var previous = first.tree
        previous.rootIsMountPoint = [:]
        let second = await fs.scanner().scan(
            previous: previous, roots: ["/r"], scope: nil, relistAll: false)
        #expect(second.unreadableRoots.isEmpty)
        #expect(second.tree.flattened().videos == ["/r/a/2.MOV"])
        #expect(second.tree.rootIsMountPoint["/r"] == true, "第一輪補上掛載點旗標")
    }

    @Test("Scoped scan: mount demotion vacates through child ENOENT")
    func scopedMountDemotionKeepsSubtree() async {
        let fs = sample(rootDevice: 2)
        let first = await fullScan(fs)
        #expect(first.tree.rootIsMountPoint["/r"] == true)
        // 卸載：掛載點目錄還在，但 st_dev 回到宿主（不再是掛載點）；子目錄 ENOENT。
        fs.setDevice("/r", 1)
        fs.fail("/r/a", errno: ENOENT)
        // 局部掃描只點名 /r/a：根走 passThrough，子目錄 ENOENT 時要回頭看出空掛載點。
        let second = await fs.scanner().scan(
            previous: first.tree, roots: ["/r"], scope: ["/r/a"], relistAll: false)
        #expect(second.unreadableRoots == ["/r"])
        #expect(second.tree.flattened().videos == ["/r/a/2.MOV"])
        #expect(second.tree.rootIsMountPoint["/r"] == true, "沿用上一輪旗標")
    }

    @Test("Mount demotion is treated as unreadable, not deletion")
    func mountDemotionKeepsSubtree() async {
        let fs = sample(rootDevice: 2)
        let first = await fullScan(fs)
        #expect(first.tree.rootIsMountPoint["/r"] == true)
        // 卸載後留下空目錄：st_dev 等於父目錄 → 不再是掛載點。
        fs.setDevice("/r", 1)
        fs.remove("/r/a", dirModified: 200)
        fs.remove("/r/1.jpg", dirModified: 200)
        let second = await fs.scanner().scan(
            previous: first.tree, roots: ["/r"], scope: nil, relistAll: true)
        #expect(second.unreadableRoots == ["/r"])
        #expect(second.tree.flattened().videos == ["/r/a/2.MOV"])
        #expect(second.tree.rootIsMountPoint["/r"] == true, "沿用上一輪旗標，下一輪才能繼續辨認")
    }

    @Test("Remount with a new st_dev that is still a mount point rescans and completes")
    func remountStillMountPointRescansAndCompletes() async {
        let fs = sample(rootDevice: 2)
        let first = await fullScan(fs)
        #expect(first.tree.rootIsMountPoint["/r"] == true)
        // 正常重新掛載：裝置號變了，但仍是掛載點（≠ 父目錄）。
        fs.setDevice("/r", 7)
        fs.setDevice("/r/a", 7)
        fs.setDevice("/r/a/deep", 7)
        fs.addFile("/r/new.jpg", dirModified: 300)
        let second = await fs.scanner().scan(
            previous: first.tree, roots: ["/r"], scope: nil, relistAll: true)
        #expect(second.unreadableRoots.isEmpty, "重新掛載後可標完整")
        #expect(second.tree.rootIsMountPoint["/r"] == true)
        #expect(second.tree.flattened().images.contains("/r/new.jpg"))
        #expect(second.tree.flattened().videos == ["/r/a/2.MOV"])
    }

    @Test("An emptied regular folder is complete deletion, not an unreadable mount")
    func emptiedRegularFolderIsCompleteDeletion() async {
        let fs = sample(rootDevice: 1) // 與父目錄同裝置＝一般資料夾
        let first = await fullScan(fs)
        #expect(first.tree.rootIsMountPoint["/r"] == false)
        fs.remove("/r/a", dirModified: 200)
        fs.remove("/r/1.jpg", dirModified: 200)
        let second = await fs.scanner().scan(
            previous: first.tree, roots: ["/r"], scope: nil, relistAll: true)
        #expect(second.unreadableRoots.isEmpty, "清單可標完整，影片同步不會被擋住")
        #expect(second.tree.flattened().images.isEmpty)
        #expect(second.tree.flattened().videos.isEmpty)
        #expect(second.tree.rootIsMountPoint["/r"] == false)
    }

    @Test("A regular folder left with only .json is a complete deletion")
    func regularFolderWithOnlyJSONIsCompleteDeletion() async {
        // 舊行為：run() 只看媒體／子目錄「空」、rootLooksVacated 看所有非隱藏項——
        // 照片刪光只剩 .json 時全量／增量會被誤判成空掛載點。
        let fs = FakeFileSystem()
        fs.mkdir("/", device: 1)
        fs.mkdir("/r", device: 1)
        fs.addFile("/r/photo.jpg", dirModified: 100)
        fs.addFile("/r/meta.json", dirModified: 100)
        let first = await fullScan(fs)
        #expect(first.tree.flattened().images == ["/r/photo.jpg"])
        fs.remove("/r/photo.jpg", dirModified: 200)
        let second = await fs.scanner().scan(
            previous: first.tree, roots: ["/r"], scope: nil, relistAll: true)
        #expect(second.unreadableRoots.isEmpty, "只剩 .json 仍是一般刪除，可標完整")
        #expect(second.tree.flattened().images.isEmpty)
        #expect(second.tree.flattened().videos.isEmpty)
        #expect(second.tree.directories["/r"]?.files.isEmpty == true)
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
