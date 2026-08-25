//  VideoDownloadService.swift
//  呼叫使用者機器上的 yt-dlp 把網址存成本機影片檔。
//
//  Foldwall 不做串流解析。這裡只是起一個 Process、把輸出收回來、
//  把結果放進影片來源目錄。

import Foundation
import FoldwallCore

@MainActor
@Observable
final class VideoDownloadService {

    private(set) var state: VideoDownloadState = .idle
    private(set) var lastLine = ""

    @ObservationIgnored private var task: Task<Void, Never>?

    /// 工具在不在。介面靠它決定要不要顯示安裝提示。
    var toolURL: URL? { VideoDownloadTool.locate() }

    func download(_ urlString: String) {
        guard task == nil else { return }
        guard VideoDownloadTool.isPlausible(urlString) else {
            state = .failed(reason: "網址格式不對")
            return
        }
        guard let tool = toolURL else {
            state = .failed(reason: "找不到 yt-dlp。用 `brew install yt-dlp` 安裝後再試。")
            return
        }

        let destination = AppPaths.standard().downloadedVideos
        state = .running
        lastLine = ""

        task = Task { @MainActor [weak self] in
            defer { self?.task = nil }
            let result = await Self.run(tool: tool, url: urlString, destination: destination)
            guard let self else { return }
            self.state = result.state
            self.lastLine = result.tail
            Log.video.info("下載結束：\(result.state.summary, privacy: .public)")
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    // MARK: - 私有

    private static func run(
        tool: URL, url: String, destination: URL
    ) async -> (state: VideoDownloadState, tail: String) {
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: destination, withIntermediateDirectories: true)

                let process = Process()
                process.executableURL = tool
                process.arguments = VideoDownloadTool.arguments(url: url, destination: destination)
                // 有些站要走系統代理；把環境保留給工具自己判斷
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let output = String(decoding: data, as: UTF8.self)
                let tail = output.split(separator: "\n").last.map(String.init) ?? ""

                guard process.terminationStatus == 0 else {
                    return (.failed(reason: Self.explain(tail)), tail)
                }
                // yt-dlp 會印出目的檔名；抓不到就退回一句話
                let name = Self.destinationName(from: output) ?? "已下載"
                return (.finished(name: name), tail)
            } catch {
                return (.failed(reason: (error as NSError).localizedDescription), "")
            }
        }.value
    }

    /// yt-dlp 的錯誤訊息很長，取最有資訊量的那一段。
    nonisolated private static func explain(_ line: String) -> String {
        guard !line.isEmpty else { return "下載失敗（工具沒有輸出訊息）" }
        if let range = line.range(of: "ERROR: ") {
            return String(line[range.upperBound...])
        }
        return line
    }

    nonisolated private static func destinationName(from output: String) -> String? {
        // "[download] Destination: /path/name.mp4" 或 "[Merger] Merging formats into ..."
        for line in output.split(separator: "\n").reversed() {
            for marker in ["Destination: ", "Merging formats into \""] {
                if let range = line.range(of: marker) {
                    let path = line[range.upperBound...].trimmingCharacters(
                        in: CharacterSet(charactersIn: "\" "))
                    return URL(filePath: String(path)).lastPathComponent
                }
            }
        }
        return nil
    }
}
