import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import FoldwallCore

final class ImageTranscoderTests: XCTestCase {

    private func encoded(_ type: UTType, width: Int, height: Int, orientation: Int? = nil) throws -> Data {
        let image = TestImage.solid(0.3, 0.7, 0.2, size: 1)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let output = NSMutableData()
        let dest = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return output as Data
    }

    private func type(of data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    /// 來源已經是 JPEG 就原樣回傳：重編碼只會掉畫質又花時間。
    func testJPEGPassesThroughUntouched() throws {
        let jpeg = try encoded(.jpeg, width: 200, height: 150)
        XCTAssertEqual(ImageTranscoder.jpegData(from: jpeg), jpeg)
    }

    func testPNGIsTranscodedToJPEG() throws {
        let png = try encoded(.png, width: 200, height: 150)
        let result = try XCTUnwrap(ImageTranscoder.jpegData(from: png))
        XCTAssertEqual(type(of: result), UTType.jpeg.identifier)
        XCTAssertNotEqual(result, png)
    }

    /// 方向要跟著過去，否則直式照片在蒙太奇裡會躺著。
    func testOrientationSurvivesTranscoding() throws {
        let png = try encoded(.png, width: 400, height: 200, orientation: 6)
        let result = try XCTUnwrap(ImageTranscoder.jpegData(from: png))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(result as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyOrientation] as? Int, 6)
    }

    /// 轉出來的要能被管線讀回去——這是它唯一的用途。
    func testResultIsLoadableByTheStillPipeline() throws {
        let png = try encoded(.png, width: 600, height: 400)
        let jpeg = try XCTUnwrap(ImageTranscoder.jpegData(from: png))
        let url = URL.temporaryDirectory.appending(path: "foldwall-tc-\(UUID().uuidString).jpg")
        try jpeg.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try ImageLoader.load(url, maxPixel: 300, minimumShortSide: 256)
        XCTAssertLessThanOrEqual(max(loaded.width, loaded.height), 300)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(ImageTranscoder.jpegData(from: Data("not an image".utf8)))
        XCTAssertNil(ImageTranscoder.jpegData(from: Data()))
    }
}
