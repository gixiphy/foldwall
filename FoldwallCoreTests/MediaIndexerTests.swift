import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FoldwallCore

final class MediaIndexerTests: XCTestCase {

    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = URL.temporaryDirectory
            .appending(path: "foldwall-fixtures-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: fixtureRoot.appending(path: "sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fixtureRoot.appending(path: ".hidden"), withIntermediateDirectories: true)

        try writePNG(fixtureRoot.appending(path: "a.JPG"), width: 400, height: 300)   // 大小寫不敏感
        try writePNG(fixtureRoot.appending(path: "sub/c.png"), width: 300, height: 300)
        try writePNG(fixtureRoot.appending(path: "tiny.png"), width: 64, height: 64)   // 短邊 <256，抽片時才剔除
        try writePNG(fixtureRoot.appending(path: ".hidden/d.png"), width: 400, height: 400)
        try Data("not a real movie".utf8).write(to: fixtureRoot.appending(path: "b.mp4"))
        try Data("{}".utf8).write(to: fixtureRoot.appending(path: "note.json"))
        try Data().write(to: fixtureRoot.appending(path: ".DS_Store"))
        try Data().write(to: fixtureRoot.appending(path: "._a.JPG"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    private func writePNG(_ url: URL, width: Int, height: Int) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    func testScanClassifiesAndSkipsSidecars() async {
        let items = await MediaIndexer().scan(roots: [fixtureRoot])
        let names = Set(items.map { $0.url.lastPathComponent.lowercased() })

        XCTAssertTrue(names.contains("a.jpg"), "副檔名大小寫不敏感")
        XCTAssertTrue(names.contains("b.mp4"))
        XCTAssertTrue(names.contains("c.png"), "應遞迴掃子目錄")

        XCTAssertFalse(names.contains("note.json"), "sidecar JSON 不進池")
        XCTAssertFalse(names.contains(".ds_store"))
        XCTAssertFalse(names.contains("._a.jpg"), "AppleDouble 不進池")
        XCTAssertTrue(names.contains("tiny.png"),
                      "索引只看副檔名：尺寸門檻挪到抽片時（開檔在 SMB 上太貴）")
        XCTAssertFalse(names.contains("d.png"), "隱藏資料夾整棵略過")

        XCTAssertEqual(items.first { $0.url.lastPathComponent == "b.mp4" }?.kind, .video)
        XCTAssertEqual(items.first { $0.url.lastPathComponent == "a.JPG" }?.kind, .image)
    }

    func testEmptyRootsYieldsEmptyPool() async {
        let items = await MediaIndexer().scan(roots: [])
        XCTAssertTrue(items.isEmpty)
    }

    /// 索引不得開檔：壞掉的影像檔照樣進清單，由抽片端剔除。
    /// 這條鎖住「不在索引時讀 metadata」——那在大型 SMB 相簿上是 400 倍的代價差。
    func testScanDoesNotOpenFiles() async throws {
        let broken = fixtureRoot.appending(path: "broken.jpg")
        try Data("這不是 JPEG".utf8).write(to: broken)

        let items = await MediaIndexer().scan(roots: [fixtureRoot])
        XCTAssertTrue(items.contains { $0.url.lastPathComponent == "broken.jpg" },
                      "壞檔在索引階段驗不出來，也不該驗")
    }
}
