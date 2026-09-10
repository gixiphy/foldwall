//  VideoTimeline.swift
//  循環播放的時間軸計算。純邏輯、不碰 AVFoundation，所以測得到。
//
//  **兩個 target 各自編譯這一份**：appex 是沙盒的、不連結 FoldwallCore
//  （見 project.yml 的 FoldwallExtension.sources）。所以這裡不能用到
//  FoldwallCore 的其他型別，也不能用 `Bundle.foldwallCore` 那套字串表。
//
//  為什麼要有這個檔：系統 extension 自己把每一輪的 sample 接成一條連續的
//  時間軸（AVSampleBufferDisplayLayer 沒有「循環」這種東西，是我們自己
//  一輪一輪餵進去的）。那段算術本來散在 VideoRenderer 的三個地方、
//  各寫各的，而且埋了一個 `1/60` 的硬編碼補值——片源不是 60 fps 就每一格
//  都算錯，錯誤還會跨輪累積。搬出來之後那些規則變成看得到、測得到的東西。
//
//  三條規則：
//  1. **每一輪都把片源的起點映射到連續的輸出時間軸。** 片源的呈現起點
//     不保證是 0（剪過的 MP4、部分 MOV 都可能非零），直接把 PTS 加上
//     累積偏移的話，每一輪的接縫都會多出「起點」那麼長的一段空隙。
//  2. **一格多長優先問 sample 本身，其次問軌道，最後才用觀察到的呈現間隔。**
//     不能拿解碼順序裡相鄰的 PTS 相減——有 B-frame 的片源那個差值是負的。
//  3. **可變幀率就讓它可變。** 這裡不把任何片源當成固定幀率，只在推不出
//     長度時才拿觀察值頂著，而且會記下來讓診斷看得到。

import CoreMedia

/// 影片軌的時間資訊。`VideoRenderer` 從 `AVAssetTrack` 讀出來之後餵進這裡。
public struct VideoTrackTiming: Sendable, Equatable {

    /// 影片軌的呈現起點。**不保證是 0。**
    public var start: CMTime
    /// 影片軌的長度。
    public var duration: CMTime
    /// 一格的標稱長度：`minFrameDuration`，拿不到就用 `nominalFrameRate` 的倒數。
    /// 兩個都沒有就是 nil，那時只能靠實際觀察到的呈現間隔（見 `PresentationIntervalEstimator`）。
    public var nominalFrameDuration: CMTime?
    /// `start` 是真的量到的，不是「還不知道所以先當 0」。
    ///
    /// 差別很重要：軌道資訊是非同步載入的，而第一格可能比它先到。不知道起點
    /// 的時候 `LoopTimeline` 會拿**第一輪的第一格 PTS** 當起點——解碼順序的
    /// 第一格就是呈現順序的第一格（不然它沒有東西可以參考），所以那個值是對的，
    /// 而且比容器宣告的還準。
    public var startIsKnown: Bool

    public init(start: CMTime, duration: CMTime, nominalFrameDuration: CMTime? = nil,
                startIsKnown: Bool = true) {
        self.start = start.isNumeric ? start : .zero
        self.duration = duration.isNumeric && duration > .zero ? duration : .invalid
        self.startIsKnown = startIsKnown && start.isNumeric
        if let nominalFrameDuration, nominalFrameDuration.isNumeric, nominalFrameDuration > .zero {
            self.nominalFrameDuration = nominalFrameDuration
        } else {
            self.nominalFrameDuration = nil
        }
    }

    /// 影片軌的呈現終點。長度不明時回 `.invalid`。
    public var end: CMTime {
        guard duration.isNumeric else { return .invalid }
        return CMTimeAdd(start, duration)
    }

    /// 長度已知而且是正的。
    public var hasKnownDuration: Bool { duration.isNumeric && duration > .zero }

    /// 什麼都不知道的軌道。軌道資訊還沒載入完就用這個——起點會由第一格補上。
    public static let unknown = VideoTrackTiming(
        start: .zero, duration: .invalid, startIsKnown: false)
}

/// 從實際看到的 PTS 推「一格大概多長」。
///
/// **為什麼不能直接拿相鄰的 sample 相減**：`AVAssetReader` 吐出來的是
/// **解碼順序**，有 B-frame 的片源裡相鄰兩格的 PTS 差可能是負的、也可能是
/// 兩格的長度。所以這裡收集一個窗口內的 PTS，排序之後取**最小的正差值**——
/// 那才是呈現順序上的一格。窗口夠小（預設 24 格）所以成本可以忽略。
public struct PresentationIntervalEstimator: Sendable, Equatable {

    /// 窗口大小。要蓋得過一個 GOP 的重排序距離，又不必記整支片。
    public static let windowSize = 24

    private var window: [CMTime] = []

    public init() {}

    public mutating func note(_ pts: CMTime) {
        guard pts.isNumeric else { return }
        window.append(pts)
        if window.count > Self.windowSize { window.removeFirst(window.count - Self.windowSize) }
    }

    /// 目前窗口推出來的一格長度。窗口裡少於兩個相異的 PTS 就回 nil。
    public var estimate: CMTime? {
        guard window.count >= 2 else { return nil }
        let sorted = window.sorted()
        var smallest: CMTime?
        for index in 1 ..< sorted.count {
            let gap = CMTimeSubtract(sorted[index], sorted[index - 1])
            guard gap.isNumeric, gap > .zero else { continue }
            if let current = smallest {
                if gap < current { smallest = gap }
            } else {
                smallest = gap
            }
        }
        return smallest
    }

    /// 窗口裡的呈現間隔不只一種——**這支是可變幀率**（或有掉格／重複格）。
    ///
    /// 只是個提示，給診斷用：不會讓時間軸改用固定幀率去「修正」它。
    /// 容差取最小間隔的一成，避免時間基準換算的整數誤差被當成 VFR。
    public var looksVariable: Bool {
        guard window.count >= 3, let smallest = estimate else { return false }
        let tolerance = CMTimeMultiplyByRatio(smallest, multiplier: 1, divisor: 10)
        let sorted = window.sorted()
        for index in 1 ..< sorted.count {
            let gap = CMTimeSubtract(sorted[index], sorted[index - 1])
            guard gap.isNumeric, gap > .zero else { continue }
            if CMTimeSubtract(gap, smallest) > tolerance { return true }
        }
        return false
    }

    public mutating func reset() { window.removeAll(keepingCapacity: true) }
}

/// 一格經過時間軸換算之後的結果。
public struct RetimedSample: Sendable, Equatable {

    /// 輸出時間軸上的呈現時間。原本就無效的話這裡也是 `.invalid`。
    public var presentationTimeStamp: CMTime
    /// 輸出時間軸上的解碼時間。**跟 PTS 用同一個偏移**，解碼重排序的關係才不會被打斷。
    public var decodeTimeStamp: CMTime
    /// 長度：**原樣傳遞，這裡不發明**。片源沒給就是 `.invalid`，
    /// 推導出來的那個只拿去算循環終點（見 `end`）。
    public var duration: CMTime
    /// 這一格在輸出時間軸上的結束時間。長度推不出來時等於 PTS。
    public var end: CMTime
    /// 長度是推導出來的（sample 自己沒給）。診斷用。
    public var durationWasDerived: Bool
    /// PTS／DTS 有被動過，呼叫端得建一份改過 timing 的 copy。
    /// 偏移剛好是 0（起點是 0 的第一輪）時是 false，那時原樣送出就好。
    public var needsRetiming: Bool
}

/// 把「一輪一輪的片源時間」接成一條連續的輸出時間軸。
///
/// 用法：每換一支片呼叫 `rebase(to:)`，每一格呼叫 `admit(...)`，
/// 讀到檔尾呼叫 `advanceToNextLoop()`。深度暫停醒來要換算檔案內的位置時
/// 呼叫 `filePosition(forTimelineTime:)`。
public struct LoopTimeline: Sendable {

    /// 目前這一支的軌道時間資訊。
    public private(set) var track: VideoTrackTiming
    /// 這一輪在**輸出時間軸**上的起點。第一輪是 0。
    public private(set) var loopBase: CMTime
    /// 這一輪已經送出的最大結束時間（輸出時間軸）。
    /// 取 max 而不是「最後一格」——有 B-frame 時解碼順序的最後一格不是呈現順序的最後一格。
    public private(set) var lastEnqueuedEnd: CMTime
    /// 這一支已經播完幾輪。
    public private(set) var loopCount: Int
    /// 這一輪送出了幾格。0 表示這一輪什麼都沒讀到——呼叫端要當成異常，別空轉。
    public private(set) var samplesThisLoop: Int
    /// 到目前為止有幾格的長度是推導出來的。診斷用。
    public private(set) var derivedDurationCount: Int
    /// 上一輪的實際長度與軌道宣告長度的差。持續同號累積就是時間漂移。
    public private(set) var lastLoopDrift: CMTime

    private var intervals: PresentationIntervalEstimator

    public init(track: VideoTrackTiming = .unknown) {
        self.track = track
        self.loopBase = .zero
        self.lastEnqueuedEnd = .zero
        self.loopCount = 0
        self.samplesThisLoop = 0
        self.derivedDurationCount = 0
        self.lastLoopDrift = .zero
        self.intervals = PresentationIntervalEstimator()
    }

    /// 片源 PTS → 輸出時間軸要加的偏移。
    ///
    /// `loopBase - track.start`：把片源的起點搬到這一輪該在的位置。
    /// 第一輪且起點是 0 時它剛好是 0，那時 `needsRetiming` 就是 false。
    public var offset: CMTime {
        CMTimeSubtract(loopBase, track.start)
    }

    /// 這支片看起來是可變幀率。診斷用，不影響時間軸算法。
    public var looksVariableFrameRate: Bool { intervals.looksVariable }

    /// 換一支片：時間軸從頭開始。
    ///
    /// **換片不保留時間軸**——那是同一支循環才需要的東西。換片本來就會
    /// 重設 timebase 到 0，這裡跟著歸零才對得上。
    public mutating func rebase(to track: VideoTrackTiming) {
        self.track = track
        loopBase = .zero
        lastEnqueuedEnd = .zero
        loopCount = 0
        samplesThisLoop = 0
        derivedDurationCount = 0
        lastLoopDrift = .zero
        intervals.reset()
    }

    /// 軌道資訊晚一步到了（那是非同步載入的）。
    ///
    /// **只補長度與標稱幀長，不動起點**：起點已經由第一格量到了，那個值比
    /// 容器宣告的準，而且改它會讓已經送出去的格全部對不上。
    public mutating func noteTrackDetails(duration: CMTime?, nominalFrameDuration: CMTime?) {
        if let duration, duration.isNumeric, duration > .zero {
            track.duration = duration
        }
        if let nominalFrameDuration, nominalFrameDuration.isNumeric, nominalFrameDuration > .zero {
            track.nominalFrameDuration = nominalFrameDuration
        }
    }

    /// 從一個已知的輸出時間軸位置接著播（深度暫停醒來、錯誤恢復）。
    ///
    /// `filePosition` 已經把檔案內的位置算好了，這裡只是讓時間軸跟它對齊：
    /// 這一輪的起點退回去，好讓後面讀到的 sample 換算出來還是接在 `timelineTime` 後面。
    public mutating func resumeReading(atFilePosition filePosition: CMTime, timelineTime: CMTime) {
        guard filePosition.isNumeric, timelineTime.isNumeric else { return }
        // 讀到的第一格 PTS 大約是 filePosition，而它應該落在 timelineTime。
        // 所以 loopBase = timelineTime - (filePosition - track.start)。
        loopBase = CMTimeSubtract(timelineTime, CMTimeSubtract(filePosition, track.start))
        lastEnqueuedEnd = timelineTime
        samplesThisLoop = 0
        intervals.reset()
    }

    /// 一格進來了：換算 PTS／DTS，並更新這一輪的結束時間。
    ///
    /// - Parameters:
    ///   - pts: sample 自己的呈現時間（片源座標）。
    ///   - dts: sample 自己的解碼時間（片源座標）。無效就傳 `.invalid`。
    ///   - duration: sample 自己的長度。無效或 0 就會走推導。
    @discardableResult
    public mutating func admit(pts: CMTime, dts: CMTime, duration: CMTime) -> RetimedSample {
        // 軌道資訊還沒到，但第一格已經來了：拿它的 PTS 當這支的呈現起點。
        // 解碼順序的第一格必然也是呈現順序的第一格（它是 IDR，後面的格才參考它），
        // 所以這個值不但可用，還比容器宣告的準。
        if !track.startIsKnown, loopCount == 0, samplesThisLoop == 0, pts.isNumeric {
            track.start = pts
            track.startIsKnown = true
        }
        let offset = self.offset
        let needsRetiming = offset != .zero
        let outputPTS = pts.isNumeric ? CMTimeAdd(pts, offset) : pts
        let outputDTS = dts.isNumeric ? CMTimeAdd(dts, offset) : .invalid

        guard pts.isNumeric else {
            // 有些容器會夾帶沒有 PTS 的填充 sample。原樣放行，但不能讓它
            // 污染時間軸——`lastEnqueuedEnd` 一旦被 NaN 沾到就再也算不回來。
            return RetimedSample(
                presentationTimeStamp: pts, decodeTimeStamp: outputDTS,
                duration: duration, end: lastEnqueuedEnd,
                durationWasDerived: false, needsRetiming: needsRetiming)
        }

        intervals.note(pts)
        samplesThisLoop += 1

        let resolved = resolvedDuration(for: duration)
        if resolved.wasDerived { derivedDurationCount += 1 }

        let end: CMTime = if let length = resolved.duration {
            CMTimeAdd(outputPTS, length)
        } else {
            // 長度真的推不出來（第一格、軌道沒給幀率、窗口還沒東西）。
            // 不要憑空發明——寧可這一格的顯示時間是 0，也不要押一個錯的長度
            // 讓每一輪都多出或少掉一段。
            outputPTS
        }
        if end.isNumeric, end > lastEnqueuedEnd { lastEnqueuedEnd = end }

        return RetimedSample(
            presentationTimeStamp: outputPTS, decodeTimeStamp: outputDTS,
            duration: duration, end: end,
            durationWasDerived: resolved.wasDerived, needsRetiming: needsRetiming)
    }

    /// 一格多長：sample 自己 → 軌道標稱值 → 觀察到的呈現間隔。
    /// 三個都沒有就是 nil。
    private func resolvedDuration(for sampleDuration: CMTime) -> (duration: CMTime?, wasDerived: Bool) {
        if sampleDuration.isNumeric, sampleDuration > .zero {
            return (sampleDuration, false)
        }
        if let nominal = track.nominalFrameDuration {
            return (nominal, true)
        }
        if let observed = intervals.estimate {
            return (observed, true)
        }
        return (nil, true)
    }

    /// 讀到檔尾，換下一輪。
    ///
    /// 下一輪的起點就是這一輪的結束時間——**不是** `loopBase + 軌道長度`：
    /// 容器宣告的長度跟實際 sample 蓋到的範圍常常不一樣（尾端補零、
    /// 剪輯留下的殘值），用宣告值會在每個接縫留下固定的空隙或重疊。
    ///
    /// 這一輪一格也沒讀到時退回宣告長度，否則 `loopBase` 停在原地，
    /// 下一輪整個蓋在這一輪上面。
    /// - Returns: 這一輪有沒有正常結束（讀到至少一格、時間有往前走）。
    @discardableResult
    public mutating func advanceToNextLoop() -> Bool {
        let advanced = samplesThisLoop > 0 && lastEnqueuedEnd > loopBase
        if advanced {
            if track.hasKnownDuration {
                lastLoopDrift = CMTimeSubtract(CMTimeSubtract(lastEnqueuedEnd, loopBase), track.duration)
            }
            loopBase = lastEnqueuedEnd
        } else if track.hasKnownDuration {
            loopBase = CMTimeAdd(loopBase, track.duration)
            lastEnqueuedEnd = loopBase
        }
        loopCount += 1
        samplesThisLoop = 0
        intervals.reset()
        return advanced
    }

    /// 輸出時間軸上的某個時刻，對應到**檔案裡**的哪個位置。
    ///
    /// 深度暫停醒來要接著播時用這個。**不能拿 timebase 的值直接去 seek**：
    /// 那是跨輪累積的時間，播過第一輪之後就超出檔長了，`AVAssetReader`
    /// 讀不到東西，整輪空轉之後從頭開始——看起來就是「醒來會重播一次」。
    ///
    /// 落在檔案範圍外（時間軸漂了、軌道長度不明）就回起點，從頭播。
    public func filePosition(forTimelineTime timelineTime: CMTime) -> CMTime {
        guard timelineTime.isNumeric else { return track.start }
        let position = CMTimeAdd(CMTimeSubtract(timelineTime, loopBase), track.start)
        guard position.isNumeric, position >= track.start else { return track.start }
        guard track.hasKnownDuration else {
            // 長度不明：只能相信算出來的值，但不能是負的（上面擋掉了）。
            return position
        }
        // 最後一格附近就別接了，直接從頭——剩不到一格的內容 seek 過去只會立刻 EOF。
        let tail = track.nominalFrameDuration ?? CMTimeMultiplyByRatio(track.duration, multiplier: 1, divisor: 1000)
        guard position < CMTimeSubtract(track.end, tail) else { return track.start }
        return position
    }
}
