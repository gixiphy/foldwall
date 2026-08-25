//  BookmarkCodec.swift
//  普通 bookmark 往返。**不用** security scope：v1 不沙盒，那組 API 在非沙盒 app 無效，
//  執行期權限由 TCC 管（讀不到＝離線，見 FolderStore）。

import Foundation

public enum BookmarkCodec {

    public struct Resolved: Sendable, Equatable {
        public var url: URL
        /// bookmark 已過期（路徑搬移等）→ 呼叫端應重建並存回。
        public var isStale: Bool
    }

    public static func data(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func resolve(_ data: Data) throws -> Resolved {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return Resolved(url: url, isStale: isStale)
    }
}
