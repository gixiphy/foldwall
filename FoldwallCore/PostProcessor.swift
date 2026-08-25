//  PostProcessor.swift
//  整張合成完再套。none 必須原圖返回（identity）。

import CoreImage
import CoreGraphics

public enum PostProcessor {

    nonisolated(unsafe) private static let context = CIContext(options: [.useSoftwareRenderer: false])

    public static func apply(
        _ image: CGImage,
        effect: PostProcess,
        rng: inout some RandomNumberGenerator
    ) -> CGImage {
        let resolved = effect.resolved(using: &rng)
        guard resolved != .none else { return image }

        let input = CIImage(cgImage: image)
        let output: CIImage?

        switch resolved {
        case .grayscale:
            output = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        case .desaturate:
            output = input.applyingFilter("CIColorControls",
                                          parameters: [kCIInputSaturationKey: PostProcess.desaturationFactor])
        case .sepia:
            output = input.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.85])
        case .none, .random:
            output = nil   // random 已在上面解析掉
        }

        guard let output,
              let rendered = context.createCGImage(output, from: input.extent)
        else { return image }   // 濾鏡失敗不能讓桌布消失，退回原圖

        return rendered
    }
}
