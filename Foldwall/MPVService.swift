//  MPVService.swift
//  libmpv 的偵測、版本與更新提示——跟 PlaylistService 對 yt-dlp 做的事一樣。
//
//  Foldwall 不附帶、不下載、不替使用者跑 brew。這裡只回答四個問題給設定頁：
//  裝了沒、裝的是哪版、上游是哪版、行程裡跑的是不是磁碟上那版。
//  判斷全在 MPVRuntime（純邏輯、有測試），這裡只負責跑子行程、打網路、存結果。

import FoldwallCore
import Foundation

@MainActor
@Observable
final class MPVService {

    /// 磁碟上的 `libmpv.2.dylib`。設定頁開頁時查一次。
    private(set) var libraryPath: URL?
    /// `mpv --version` 的第一行。工具還沒問過、或根本沒裝就是 nil。
    private(set) var installedVersion: String?
    /// Homebrew formula 的 stable 版本。查不到就是 nil。
    private(set) var latestVersion: String?

    /// 裝的這版落後 Homebrew 了嗎。**任何一邊查不到都是 false**。
    var isOutdated: Bool {
        MPVRuntime.isOutdated(installed: installedVersion, latest: latestVersion)
    }

    /// 行程裡實際載入的版本（`mpv-version`）。還沒載入過就是 nil。
    var loadedVersion: String? { MPVLibrary.loadedIfAny?.version }

    /// 磁碟上的跟載入中的不是同一版：使用者剛 `brew upgrade mpv` 過，重新啟動才生效。
    var needsRestart: Bool {
        MPVRuntime.needsRestart(loaded: loadedVersion, onDisk: installedVersion)
    }

    /// 兩次查詢上游版本的最短間隔。一天問一次綽綽有餘。
    private static let versionCheckInterval: TimeInterval = 24 * 60 * 60
    private var lastVersionCheck: Date?

    /// 查一次。設定頁開到影片那一頁、或使用者把核心切到 mpv 時呼叫。
    ///
    /// 上游查詢綁在「真的選了 mpv 或真的裝了」上：沒用到這功能的人不該因為
    /// 開了 App 就多一個對外請求。
    func refresh(force: Bool = false) {
        libraryPath = MPVRuntime.locateLibrary()
        guard let executable = MPVRuntime.locateExecutable() else {
            installedVersion = nil
            latestVersion = nil
            return
        }
        if !force, let last = lastVersionCheck,
           Date.now.timeIntervalSince(last) < Self.versionCheckInterval { return }
        lastVersionCheck = .now

        Task { @MainActor [weak self] in
            let installed = await Task.detached(priority: .utility) {
                Self.runVersion(executable: executable)
            }.value
            self?.installedVersion = installed

            // 上游那邊查不到就算了：版本提示不值得讓使用者看到錯誤。
            guard let (data, response) = try? await URLSession.shared.data(
                for: MPVRuntime.latestFormulaRequest()),
                (response as? HTTPURLResponse)?.statusCode == 200
            else { return }
            self?.latestVersion = MPVRuntime.parseLatestFormula(data)
        }
    }

    nonisolated private static func runVersion(executable: URL) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = MPVRuntime.versionArguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            guard let line = text.split(whereSeparator: \.isNewline).first else { return nil }
            return String(line).trimmingCharacters(in: .whitespaces)
        } catch {
            return nil
        }
    }
}
