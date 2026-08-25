import XCTest
import CoreGraphics
@testable import FoldwallCore

/// 測試用工具：純色圖與像素取樣。
enum TestImage {

    static func solid(_ r: Double, _ g: Double, _ b: Double, size: Int = 64) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    /// 回傳 RGBA bytes，供像素比對與 checksum。
    static func bytes(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buffer
    }

    static func centerPixel(_ image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8) {
        let raw = bytes(image)
        let idx = ((image.height / 2) * image.width + image.width / 2) * 4
        return (raw[idx], raw[idx + 1], raw[idx + 2])
    }
}

final class PostProcessorTests: XCTestCase {

    private var rng = SeededGenerator(seed: 1)

    func testGrayscaleMakesChannelsEqual() {
        let red = TestImage.solid(1, 0, 0)
        let out = PostProcessor.apply(red, effect: .grayscale, rng: &rng)
        let p = TestImage.centerPixel(out)

        XCTAssertEqual(Int(p.r), Int(p.g), accuracy: 2, "灰階後 R≈G")
        XCTAssertEqual(Int(p.g), Int(p.b), accuracy: 2, "灰階後 G≈B")
        XCTAssertGreaterThan(Int(p.r), 0, "不該整張變黑")
    }

    func testNoneIsIdentity() {
        let src = TestImage.solid(0.8, 0.2, 0.2)
        let out = PostProcessor.apply(src, effect: .none, rng: &rng)
        XCTAssertEqual(TestImage.bytes(src), TestImage.bytes(out), "none 必須原圖返回")
    }

    func testDesaturateUsesFixedFactor() {
        XCTAssertEqual(PostProcess.desaturationFactor, 0.4, "v1 定值，改了要連規格一起改")

        let red = TestImage.solid(1, 0, 0)
        let out = PostProcessor.apply(red, effect: .desaturate, rng: &rng)
        let p = TestImage.centerPixel(out)

        // 去飽和：仍偏紅，但綠藍被拉起來
        XCTAssertGreaterThan(Int(p.r), Int(p.g), "應該還看得出原色相")
        XCTAssertGreaterThan(Int(p.g), 10, "飽和度已明顯降低")
    }

    func testSepiaShiftsTowardWarm() {
        let gray = TestImage.solid(0.5, 0.5, 0.5)
        let out = PostProcessor.apply(gray, effect: .sepia, rng: &rng)
        let p = TestImage.centerPixel(out)
        XCTAssertGreaterThan(Int(p.r), Int(p.b), "棕褐色：紅通道應高於藍通道")
    }

    func testRandomResolvesDeterministicallyForSameSeed() {
        var a = SeededGenerator(seed: 99)
        var b = SeededGenerator(seed: 99)
        let picks = (0..<8).map { _ in PostProcess.random.resolved(using: &a) }
        let same = (0..<8).map { _ in PostProcess.random.resolved(using: &b) }
        XCTAssertEqual(picks, same, "同 seed 的 random 序列必須可重現")
        XCTAssertFalse(picks.contains(.random), "random 必須解析成具體效果")
    }
}
