//  ImageTranscoder.swift
//  把照片圖庫給的原始資料轉成快取用的 JPEG。
//
//  **不要用 NSImage → tiffRepresentation → NSBitmapImageRep 那條路。**
//  `tiffRepresentation` 會把整張圖展開成未壓縮點陣：一張 4000×3000 就是約 48MB，
//  一輪匯出 20 張就是 1GB 的記憶體churn，而且那段程式原本跑在主執行緒上。
//
//  ImageIO 的 `CGImageDestinationAddImageFromSource` 直接轉碼，不經過完整解壓，
//  而且會把 EXIF（含方向）一起帶過去——下游 ImageLoader 本來就會讀方向。

import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageTranscoder {

    /// **最高品質——這是「原圖」那一端。** 相簿匯出來的是合成用的素材，
    /// 之後還要再縮放、再經過一次 JPEG 編碼。在這裡先掉一次畫質，
    /// 最後那張就是兩次損失疊起來的。要省空間該省在合成輸出
    /// （見 StillPipeline.jpegQuality），不是省在來源。
    /// （本來就是 JPEG 的來源完全不重編碼，見下面。）
    public static let quality: Double = 1.0

    /// - Returns: 可直接寫檔的 JPEG 資料；來源本來就是 JPEG 就原樣回傳（完全不重編碼）。
    ///   認不得的格式回 nil。
    public static func jpegData(from data: Data, quality: Double = quality) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        // 已經是 JPEG 就別再壓一次：重編碼只會掉畫質又花時間
        if let type = CGImageSourceGetType(source) as String?,
           type == UTType.jpeg.identifier {
            return data
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        CGImageDestinationAddImageFromSource(destination, source, 0, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
