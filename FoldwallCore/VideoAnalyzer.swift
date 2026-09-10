//  VideoAnalyzer.swift
//  把一支影片的事實讀出來，填進 `VideoSourceProfile`。
//
//  分兩層，因為成本差三個數量級：
//
//  - `profile(of:)` 只讀檔頭：編碼、尺寸、旋轉、色彩、位元率、宣告幀率、
//    軌道起訖。走 SMB 也就是幾毫秒到幾百毫秒。
//  - `timingAnalysis(of:)` 要把整條軌道的時間戳走一遍。這是唯一能回答
//    「實際幀間隔是不是均勻」「有沒有格沒帶長度」「時間戳有沒有重複」的方法，
//    但它會把整支片讀過一次。**只在診斷模式或已知的問題片源上跑。**
//
//  統計那段是純函式（`TimingStatistics`），所以測得到；AVFoundation 只負責
//  把 sample 的時間戳撈出來餵給它。

import AVFoundation
import CoreMedia
import Foundation

public enum VideoAnalyzer {

    /// 深入分析最多走幾格。一支 30 秒 60 fps 的桌布素材是 1800 格；
    /// 上限訂在這個量級的幾倍，長片就只分析開頭那段（會標在 `sampleCount` 上）。
    public static let defaultSampleLimit = 20_000

    // MARK: - 檔頭

    /// 讀檔頭層級的事實。讀不到的欄位留 nil——**不要用預設值頂替**。
    public static func profile(of url: URL) async -> VideoSourceProfile {
        var result = VideoSourceProfile(sourceKey: sourceKey(for: url))
        result.analyzedAt = .now

        if url.isFileURL {
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .volumeIsLocalKey])
            result.fileSize = values?.fileSize.map(Int64.init)
            result.contentModified = values?.contentModificationDate
            result.isLocal = values?.volumeIsLocal
        } else {
            result.isLocal = false
        }

        let asset = AVURLAsset(url: url)
        result.containerDurationSeconds = (try? await asset.load(.duration))
            .flatMap { $0.isNumeric ? $0.seconds : nil }

        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return result
        }

        if let timeRange = try? await track.load(.timeRange), timeRange.start.isNumeric {
            result.trackStartSeconds = timeRange.start.seconds
            if timeRange.duration.isNumeric { result.trackDurationSeconds = timeRange.duration.seconds }
        }
        if let rate = try? await track.load(.nominalFrameRate), rate > 0, rate.isFinite {
            result.nominalFrameRate = Double(rate)
        }
        if let minFrameDuration = try? await track.load(.minFrameDuration),
           minFrameDuration.isNumeric, minFrameDuration > .zero {
            result.minFrameDurationSeconds = minFrameDuration.seconds
        }
        if let dataRate = try? await track.load(.estimatedDataRate), dataRate > 0, dataRate.isFinite {
            result.estimatedDataRate = Double(dataRate)
        }
        if let size = try? await track.load(.naturalSize) {
            result.pixelWidth = Int(size.width.rounded())
            result.pixelHeight = Int(size.height.rounded())
            if let transform = try? await track.load(.preferredTransform) {
                // **套過旋轉才是顯示尺寸。** 直拍的手機影片 naturalSize 是橫的，
                // 用原始尺寸算長寬比會反過來，畫面就會框錯。
                let display = size.applying(transform)
                result.displayWidth = Double(abs(display.width))
                result.displayHeight = Double(abs(display.height))
                result.rotationDegrees = rotationDegrees(of: transform)
            }
        }
        result.isHDR = track.hasMediaCharacteristic(.containsHDRVideo)

        if let descriptions = try? await track.load(.formatDescriptions),
           let description = descriptions.first {
            result.codec = fourCC(CMFormatDescriptionGetMediaSubType(description))
            result.colorPrimaries = stringExtension(
                description, kCMFormatDescriptionExtension_ColorPrimaries)
            result.transferFunction = stringExtension(
                description, kCMFormatDescriptionExtension_TransferFunction)
            if let depth = CMFormatDescriptionGetExtension(
                description, extensionKey: kCMFormatDescriptionExtension_Depth) as? NSNumber {
                result.bitDepth = depth.intValue
            }
            if result.isHDR != true, let transfer = result.transferFunction {
                // 有些容器不宣告 HDR 特性，但轉換函數已經說明白了。
                result.isHDR = transfer.contains("2100") || transfer.contains("2084")
            }
        }
        return result
    }

    /// 穩定識別：本機檔用標準化路徑，遠端用完整網址。
    public static func sourceKey(for url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    private static func rotationDegrees(of transform: CGAffineTransform) -> Int {
        let radians = atan2(Double(transform.b), Double(transform.a))
        let degrees = Int((radians * 180 / .pi).rounded())
        return ((degrees % 360) + 360) % 360
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func stringExtension(
        _ description: CMFormatDescription, _ key: CFString,
    ) -> String? {
        guard let value = CMFormatDescriptionGetExtension(description, extensionKey: key)
        else { return nil }
        if let text = value as? String { return text }
        return String(describing: value)
    }

    // MARK: - 時間戳

    /// 走過整條軌道的時間戳。**這會把影片讀一遍**，只在診斷或問題片源上跑。
    ///
    /// - Returns: 開不了檔或讀不到任何一格時回 nil——那跟「分析結果是空的」
    ///   不一樣，呼叫端要能分辨。
    public static func timingAnalysis(
        of url: URL, limit: Int = defaultSampleLimit,
    ) async -> VideoSourceProfile.TimingAnalysis? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        var samples: [SampleTiming] = []
        samples.reserveCapacity(min(limit, 4096))
        while samples.count < limit, let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { break }
            let duration = CMSampleBufferGetDuration(buffer)
            samples.append(SampleTiming(
                presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer),
                duration: duration.isNumeric && duration > .zero ? duration : nil))
        }
        guard !samples.isEmpty else { return nil }

        let nominal = (try? await track.load(.minFrameDuration))
            .flatMap { $0.isNumeric && $0 > .zero ? $0 : nil }
        return TimingStatistics.analyze(samples, nominalFrameDuration: nominal)
    }

    /// 一格的時間戳。分析的輸入單位。
    public struct SampleTiming: Sendable, Equatable {
        /// 呈現時間。
        public var presentationTimeStamp: CMTime
        /// sample 自己帶的長度。**沒帶就是 nil**，不要用 0 或推導值頂替：
        /// 「有幾格沒帶長度」本身就是要回報的事實。
        public var duration: CMTime?

        public init(presentationTimeStamp: CMTime, duration: CMTime? = nil) {
            self.presentationTimeStamp = presentationTimeStamp
            self.duration = duration
        }
    }
}

/// 從時間戳算出統計。純函式，所以測得到。
public enum TimingStatistics {

    /// 間隔差多少才算「不是固定幀率」。取最小間隔的一成——時間基準換算的
    /// 整數誤差遠小於這個，真正的 VFR 或掉格遠大於這個。
    public static let variabilityTolerance = 0.1

    /// - Parameter samples: **解碼順序**的時間戳。呈現順序的統計會在這裡自己排。
    public static func analyze(
        _ samples: [VideoAnalyzer.SampleTiming], nominalFrameDuration: CMTime? = nil,
    ) -> VideoSourceProfile.TimingAnalysis {
        var analysis = VideoSourceProfile.TimingAnalysis(sampleCount: samples.count)
        analysis.samplesMissingDuration = samples.count { $0.duration == nil }

        let valid = samples.filter(\.presentationTimeStamp.isNumeric)
        guard !valid.isEmpty else { return analysis }

        // 解碼順序裡 PTS 往回走 → 有 B-frame。這是正常的，記下來是因為
        // 它會影響「循環終點怎麼算」（不能拿最後解碼的那格當結尾）。
        for index in 1 ..< max(valid.count, 1) where
            valid[index].presentationTimeStamp < valid[index - 1].presentationTimeStamp {
            analysis.hasBFrames = true
            break
        }

        let sorted = valid.map(\.presentationTimeStamp).sorted()
        analysis.firstPresentationSeconds = sorted.first?.seconds

        var intervals: [Double] = []
        var duplicates = 0
        for index in 1 ..< max(sorted.count, 1) {
            let gap = CMTimeSubtract(sorted[index], sorted[index - 1])
            guard gap.isNumeric else { continue }
            if gap <= .zero {
                // 排序過還相等 → 兩格宣稱在同一時刻呈現。這是壞掉的時間戳，
                // 跟 B-frame 重排序不是同一回事。
                duplicates += 1
            } else {
                intervals.append(gap.seconds)
            }
        }
        analysis.nonMonotonicPresentationCount = duplicates

        if !intervals.isEmpty {
            let ordered = intervals.sorted()
            analysis.minIntervalSeconds = ordered.first
            analysis.maxIntervalSeconds = ordered.last
            analysis.medianIntervalSeconds = ordered[ordered.count / 2]
            if let smallest = ordered.first, let largest = ordered.last, smallest > 0 {
                analysis.isVariableFrameRate = largest > smallest * (1 + variabilityTolerance)
            }
        }

        // 最後一格的結尾：它自己的長度 → 軌道標稱值 → 量到的中位間隔。
        // 三個都沒有就留 nil，不要押一個值——那正是舊程式碼用 1/60 犯的錯。
        if let last = sorted.last {
            let tail = samples.last(where: { $0.presentationTimeStamp == last })?.duration
                ?? nominalFrameDuration
                ?? analysis.medianIntervalSeconds.map {
                    CMTime(seconds: $0, preferredTimescale: 600_000)
                }
            analysis.lastPresentationEndSeconds = tail.map { CMTimeAdd(last, $0).seconds }
        }
        return analysis
    }
}
