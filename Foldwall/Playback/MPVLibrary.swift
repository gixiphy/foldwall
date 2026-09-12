//  MPVLibrary.swift
//  一個行程只 dlopen libmpv 一次，握著到行程結束。
//
//  `brew upgrade mpv` 會換掉磁碟上的檔：已映射的舊庫照樣能用，但之後再 dlopen 會拿到新版，
//  兩台螢幕各跑一版是在賭。新版一律下次啟動才生效（設定頁會提示重新啟動，見 MPVService）。
//
//  載入後先驗兩件事再交出去：API 主版號跟我們釘死的標頭一樣（ABI 相容）、
//  release 不低於原型驗過的最低版本。判準都在 MPVRuntime，這裡只是呼叫順序。

import FoldwallCore
import Foundation

@MainActor
enum MPVLibrary {

    struct Loaded {
        let handle: MPVLibraryHandle
        let path: URL
        /// `mpv-version` 屬性，例如 `mpv v0.41.0`。行程裡實際跑的那份。
        let version: String?
        /// `mpv_client_api_version()`。
        let apiVersion: UInt
    }

    enum Outcome {
        case loaded(Loaded)
        case failed(MPVRuntime.LoadFailure)

        var loaded: Loaded? {
            if case .loaded(let value) = self { return value }
            return nil
        }

        var failure: MPVRuntime.LoadFailure? {
            if case .failed(let value) = self { return value }
            return nil
        }
    }

    private static var cached: Outcome?

    /// 第一次問才載，之後都是同一份答案——連失敗也是：找不到檔、API 不合，
    /// 這個行程裡就是這樣了，`brew install` 完要重新啟動才會用上。
    static var outcome: Outcome {
        if let cached { return cached }
        let result = load()
        cached = result
        return result
    }

    /// 已經載過了嗎（不觸發載入）。設定頁顯示「載入中的版本」用。
    static var loadedIfAny: Loaded? { cached?.loaded }

    private static func load() -> Outcome {
        guard let path = MPVRuntime.locateLibrary() else { return .failed(.notInstalled) }
        let handle: MPVLibraryHandle
        do {
            handle = try MPVLibraryHandle.open(atPath: path.path)
        } catch {
            let failure = MPVRuntime.classifyLoadError(error.localizedDescription)
            Log.video.error("libmpv 載入失敗：\(error.localizedDescription, privacy: .public)")
            return .failed(failure)
        }
        let api = UInt(handle.clientAPIVersion)
        if let failure = MPVRuntime.checkAPIVersion(api) {
            Log.video.error("libmpv API 版本不合：\(api >> 16, privacy: .public)")
            return .failed(failure)
        }
        let version = handle.probeVersionString(
            options: Dictionary(uniqueKeysWithValues: MPVRuntime.probeOptions()))
        if let parsed = version.flatMap(MPVRuntime.parseVersion),
           let failure = MPVRuntime.checkMinimum(parsed) {
            Log.video.error("libmpv 太舊：\(parsed.description, privacy: .public)")
            return .failed(failure)
        }
        Log.video.info(
            "libmpv 已載入：\(path.path, privacy: .public)（\(version ?? "版本未知", privacy: .public)，API \(api >> 16, privacy: .public).\(api & 0xffff, privacy: .public)）")
        return .loaded(Loaded(handle: handle, path: path, version: version, apiVersion: api))
    }
}
