import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FoldwallCore

final class ImageLoaderTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL.temporaryDirectory.appending(path: "foldwall-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    @discardableResult
    private func writeJPEG(_ name: String, width: Int, height: Int, orientation: Int? = nil) throws -> URL {
        let url = tmp.appending(path: name)
        let image = TestImage.solid(0.9, 0.3, 0.1, size: 1)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    // MARK: - 短邊門檻（索引不再驗，改在載入時）

    func testRejectsImageBelowMinimumShortSide() throws {
        let url = try writeJPEG("icon.jpg", width: 512, height: 64)
        XCTAssertThrowsError(try ImageLoader.load(url, maxPixel: 400, minimumShortSide: 256)) { error in
            XCTAssertEqual(error as? ImageLoader.Failure, .tooSmall(url), "短邊 64 < 256 應被剔除")
        }
    }

    func testAcceptsImageAtMinimumShortSide() throws {
        let url = try writeJPEG("ok.jpg", width: 512, height: 256)
        XCTAssertNoThrow(try ImageLoader.load(url, maxPixel: 400, minimumShortSide: 256), "剛好等於門檻要放行")
    }

    func testNoThresholdMeansNoSizeCheck() throws {
        let url = try writeJPEG("small.jpg", width: 64, height: 64)
        XCTAssertNoThrow(try ImageLoader.load(url, maxPixel: 400), "不給門檻就不檢查")
    }

    func testDownsamplesToMaxPixel() throws {
        let url = try writeJPEG("big.jpg", width: 1200, height: 900)
        let image = try ImageLoader.load(url, maxPixel: 200)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 200, "長邊應被限制")
        XCTAssertGreaterThan(min(image.width, image.height), 0)
    }

    func testRespectsExifOrientation() throws {
        // orientation 6 = 順時針 90°，載入後長寬應對調
        let url = try writeJPEG("rotated.jpg", width: 400, height: 200, orientation: 6)
        let image = try ImageLoader.load(url, maxPixel: 1000)
        XCTAssertGreaterThan(image.height, image.width, "EXIF 直式照片不該躺著")
    }

    func testUndecodableFileThrows() throws {
        let url = tmp.appending(path: "broken.jpg")
        try Data("this is not an image".utf8).write(to: url)
        XCTAssertThrowsError(try ImageLoader.load(url, maxPixel: 100)) { error in
            XCTAssertEqual(error as? ImageLoader.Failure, .undecodable(url), "壞檔要明確報錯，讓上層換下一張")
        }
    }

    func testMissingFileThrows() {
        let url = tmp.appending(path: "nope.png")
        XCTAssertThrowsError(try ImageLoader.load(url, maxPixel: 100))
    }

    /// 開發用：設 FOLDWALL_SAMPLE_DIR（可選 FOLDWALL_SAMPLE_SOURCE 指向真實照片資料夾）
    /// 產出樣張以肉眼檢查構圖。平常自動跳過。
    func testWriteSampleForVisualInspection() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outDir = env["FOLDWALL_SAMPLE_DIR"] else {
            throw XCTSkip("未設 FOLDWALL_SAMPLE_DIR")
        }
        let canvas = CGSize(width: 1600, height: 900)

        var images: [CGImage] = []
        if let source = env["FOLDWALL_SAMPLE_SOURCE"] {
            let items = await MediaIndexer().scan(roots: [URL(filePath: source)])
            images = items.filter { $0.kind == .image }.prefix(12)
                .compactMap { try? ImageLoader.load($0.url, maxPixel: 1600) }
        }
        if images.isEmpty {
            images = [TestImage.solid(0.9, 0.2, 0.2, size: 400),
                      TestImage.solid(0.2, 0.7, 0.3, size: 400),
                      TestImage.solid(0.2, 0.4, 0.9, size: 400),
                      TestImage.solid(0.9, 0.8, 0.2, size: 400)]
        }

        try FileManager.default.createDirectory(at: URL(filePath: outDir), withIntermediateDirectories: true)
        for (index, effect) in [PostProcess.none, .grayscale, .sepia, .desaturate].enumerated() {
            let composite = try MontageComposer().compose(
                images: images, canvas: canvas,
                recipe: MontageRecipe(pieceCount: 9, seed: UInt64(index + 1)),
                effect: effect
            )
            let url = URL(filePath: outDir).appending(path: "montage-\(effect.rawValue).png")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, composite, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
    }
}
