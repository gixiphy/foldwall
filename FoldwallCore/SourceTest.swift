//  SourceTest.swift
//  「這個來源到底通不通」的結果描述。
//
//  使用者設完一個來源，最想知道的是「我填對了嗎」。之前沒有這個能力，
//  填錯 key 的來源只會安靜地什麼都不給，要去翻 log 才看得出 missingKey。

import Foundation

public enum SourceTestResult: Sendable, Equatable {
    case untested
    case testing
    /// 通了，並回報看到幾項可用內容。
    case passed(count: Int)
    /// 通了但空的——設定沒錯，只是這個查詢／路由沒有內容。
    case empty
    case failed(reason: String)

    public var isConclusive: Bool {
        switch self {
        case .untested, .testing: false
        default: true
        }
    }

    public var symbol: String {
        switch self {
        case .untested: "circle"
        case .testing: "clock"
        case .passed: "checkmark.circle.fill"
        case .empty: "exclamationmark.circle"
        case .failed: "xmark.circle.fill"
        }
    }

    public var summary: String {
        switch self {
        case .untested: String(localized: "尚未測試", bundle: .foldwallCore)
        case .testing: String(localized: "測試中…", bundle: .foldwallCore)
        case .passed(let count): String(localized: "通了，取得 \(count) 項", bundle: .foldwallCore)
        case .empty: String(localized: "連得上，但這個查詢沒有內容", bundle: .foldwallCore)
        case .failed(let reason): reason
        }
    }

    /// 把解析出的數量翻成結果。空清單不是失敗——設定可能是對的。
    public static func fromCount(_ count: Int) -> SourceTestResult {
        count > 0 ? .passed(count: count) : .empty
    }

    /// 把錯誤翻成使用者看得懂的一句話。
    public static func fromError(_ error: Error) -> SourceTestResult {
        switch error {
        case RemoteSourceError.missingKey:
            .failed(reason: String(localized: "缺少 API key", bundle: .foldwallCore))
        case RemoteSourceError.missingEndpoint:
            .failed(reason: String(localized: "缺少網址或路由", bundle: .foldwallCore))
        case RemoteSourceError.badEndpoint(let value):
            .failed(reason: String(localized: "網址格式錯誤：\(value)", bundle: .foldwallCore))
        case RemoteSourceError.malformedResponse:
            .failed(reason: String(localized: "回應格式不符，可能不是這個來源的網址",
                                   bundle: .foldwallCore))
        case RemoteSourceError.httpStatus(let code): .failed(reason: httpReason(code))
        default: .failed(reason: (error as NSError).localizedDescription)
        }
    }

    private static func httpReason(_ code: Int) -> String {
        switch code {
        case 401, 403: String(localized: "HTTP \(code)：key 不對或沒有權限", bundle: .foldwallCore)
        case 404: String(localized: "HTTP 404：路由或網址不存在", bundle: .foldwallCore)
        case 429: String(localized: "HTTP 429：超出速率上限，稍後再試", bundle: .foldwallCore)
        case 500...599: String(localized: "HTTP \(code)：對方伺服器出錯", bundle: .foldwallCore)
        default: "HTTP \(code)"
        }
    }
}
