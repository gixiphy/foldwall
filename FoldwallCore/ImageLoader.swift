//  ImageLoader.swift
//  URL → 下採樣 CGImage。合成 5K 畫布時不把 12 張原圖全載進記憶體。

import Foundation
import ImageIO

public enum ImageLoader {

    public enum Failure: Error, Equatable {
        /// 壞檔或無法解碼 → 上層標離線、換下一張、不進池。
        case undecodable(URL)
        /// 短邊低於門檻的雜訊圖（icon、縮圖）→ 換下一張。
        case tooSmall(URL)
    }

    /// - Parameters:
    ///   - maxPixel: 長邊上限（像素），通常給 canvas 長邊。
    ///   - minimumShortSide: 短邊門檻；`nil` 不檢查。索引階段不驗尺寸（開檔太貴），
    ///     所以這道關卡在這裡——只對真的抽中的圖付這個成本。
    public static func load(_ url: URL, maxPixel: Int, minimumShortSide: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure.undecodable(url)
        }

        if let minimumShortSide {
            // 只讀 metadata，**不 decode**：不合格就別浪費一次下採樣
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int
            else { throw Failure.undecodable(url) }

            guard min(width, height) >= minimumShortSide else {
                throw Failure.tooSmall(url)
            }
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
