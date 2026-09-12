//  DesktopPlaybackSurface.swift
//  桌面視窗底下可以抽換的播放核心。
//
//  `DesktopVideoEngine` 管每台螢幕的視窗、session、排片預約、看門狗與事件紀錄；
//  **surface 只管一台螢幕上的「播放器」本身**：載入、播放、定位、縮放、狀態與釋放。
//  AVPlayer 與 mpv 各一種實作（AVPlayerSurface、MPVSurface）。
//
//  事件的「過期」由 surface 自己過濾：每次 load／adopt 換一代觀察者，舊的那代送來的
//  一律丟掉。所以 delegate 收到的永遠是「現在這支」的事，引擎不必再拿 session 比對。

import AppKit
import FoldwallCore

@MainActor
protocol DesktopPlaybackSurface: AnyObject {

    var core: DesktopPlaybackCore { get }

    /// 放進桌布視窗的那個 view。surface 的一生只有這一個。
    var view: NSView { get }

    var delegate: (any DesktopPlaybackSurfaceDelegate)? { get set }

    /// 開始播一支。
    /// - Parameters:
    ///   - loop: 單片循環——無縫接回開頭，**不會**發 `surfaceDidReachEnd`。
    ///   - seconds: 從第幾秒開始；換核心時保留時間點用。nil 從頭。
    func load(_ url: URL, location: VideoSourceLocation, loop: Bool, startAt seconds: Double?)

    /// 準備下一支。回 false＝這條路做不到（例如單片循環中），呼叫端就走「播完通知上層」。
    @discardableResult
    func preload(_ url: URL, location: VideoSourceLocation) -> Bool

    func cancelPreload()

    var hasPreloaded: Bool { get }

    /// 立刻接上已預載的那支（使用者按「下一片」）。播完自動接上的不必叫這個。
    func advanceToPreloaded()

    /// 已預載的那支現在是「正在播的」了：觀察者、播完通知都換到它身上。
    /// 播完自動接上、或 `advanceToPreloaded` 之後，引擎都會叫一次。
    func adoptPreloaded()

    /// 從頭再播同一支。
    func replay()

    /// 即時改「播完接回開頭」。回 true＝改好了，不必重建；回 false＝這條路做不到
    /// （AVPlayerLooper 是建 player 當下決定的），呼叫端整批重建。
    /// 改成循環時已預載的下一支要一併丟掉。
    func setLoop(_ loop: Bool) -> Bool

    func play()
    func pause()

    /// 只會是 fill 或 fit：「填滿高度／寬度」引擎已經化簡過了。
    func setScale(_ applied: VideoScaleMode)

    /// 播到第幾秒。換核心時保留時間點用；讀不到就 nil。
    var currentSeconds: Double? { get }

    /// 明確的錯誤：壞檔、404、憑證錯。看門狗每 10 秒問一次。
    var explicitFailure: String? { get }

    /// 想播但沒資料。看門狗用它量「等太久」。
    var isWaitingForData: Bool { get }

    /// 單片循環中還能不能不拆重建就換片。AVPlayerLooper 那條路不行（見 DesktopVideoEngine）。
    var canSwitchWhileLooping: Bool { get }

    /// 診斷報告裡這台的補充行（解碼器、掉幀計數之類）。取不到就少寫，不要編。
    func diagnosticLines() -> [String]

    /// 停止、釋放。之後不會再有任何 delegate 回呼。
    func teardown()
}

@MainActor
protocol DesktopPlaybackSurfaceDelegate: AnyObject {
    /// 正在播的那支到結尾了。有預載的話核心已經（或正要）自己接上，引擎據此換 session；
    /// 沒有預載就是停在最後一格等排片。
    func surfaceDidReachEnd(_ uuid: String)
    /// 知道影片的寬÷高了（**已套旋轉**）。
    func surface(_ uuid: String, didLearnAspect aspect: Double)
    /// 第一格真的畫出來了。
    func surfaceDidShowFirstFrame(_ uuid: String)
    /// 想播但沒資料。
    func surface(_ uuid: String, didStall reason: String?)
    /// 從停頓回來。
    func surfaceDidResume(_ uuid: String)
    /// 明確失敗，不必等看門狗。`blamesSource` 為 false 是播放器自己的問題
    /// （例如視訊輸出建不起來），不能把影片送進冷卻名單。
    func surface(_ uuid: String, didFail reason: String, blamesSource: Bool)
}

/// 點擊穿透：桌布不該吃掉使用者的滑鼠事件。
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
