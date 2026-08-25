//  ImageLoader.swift
//  URL → 下採樣 CGImage。合成 5K 畫布時不把 12 張原圖全載進記憶體。

import Foundation
import ImageIO

public enum ImageLoader {

    public enum Failure: Error, Equatable {
        /// 壞檔或無法解碼 → 上層標離線、換下一張、不進池。
        case undecodable(URL)
    }

    /// - Parameter maxPixel: 長邊上限（像素），通常給 canvas 長邊。
    public static func load(_ url: URL, maxPixel: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure.undecodable(url)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            // 尊重 EXIF 方向：直式照片不要躺著
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.undecodable(url)
        }
        return image
    }
}
