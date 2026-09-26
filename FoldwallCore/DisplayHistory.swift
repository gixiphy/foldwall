import Foundation
import Darwin

/// A rolling window shared by image draws and shuffled videos. Limits are also the
/// history retention bounds, so increasing a setting can use earlier observations.
public struct DisplayRepeatPolicy: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var hours: Int
    public var maxDisplays: Int
    public static let hourRange = 1...720
    public static let countRange = 1...100

    public init(isEnabled: Bool = true, hours: Int = 24, maxDisplays: Int = 1) {
        self.isEnabled = isEnabled
        self.hours = min(max(hours, 1), 720)
        self.maxDisplays = min(max(maxDisplays, 1), 100)
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, hours, maxDisplays }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
                  hours: try values.decodeIfPresent(Int.self, forKey: .hours) ?? 24,
                  maxDisplays: try values.decodeIfPresent(Int.self, forKey: .maxDisplays) ?? 1)
    }

    public var window: TimeInterval { Double(min(max(hours, 1), 720)) * 3600 }
    public var limit: Int { min(max(maxDisplays, 1), 100) }
}

/// Stores successful displays, never selections or preloads. The app and sandboxed
/// extension use the same file. A separate lock file survives atomic replacements;
/// each transaction reloads under flock so neither process can overwrite the other.
public final class DisplayHistory: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL?
    private var entries: [String: [Date]] = [:]

    public init(fileURL: URL? = nil) { self.fileURL = fileURL }

    public static func key(for url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path(percentEncoded: false) : url.absoluteString
    }

    public func excludedKeys(policy: DisplayRepeatPolicy, now: Date = .now) -> Set<String> {
        guard policy.isEnabled else { return [] }
        return transaction { entries in
            let cutoff = now.addingTimeInterval(-policy.window)
            return Set(entries.compactMap { key, dates in
                dates.filter { $0 > cutoff }.count >= policy.limit ? key : nil
            })
        }
    }

    public func record(_ keys: [String], now: Date = .now) {
        guard !keys.isEmpty else { return }
        transaction(write: true) { entries in
            let cutoff = now.addingTimeInterval(-720 * 3600)
            entries = entries.compactMapValues { dates in
                let recent = dates.filter { $0 > cutoff }
                return recent.isEmpty ? nil : recent
            }
            for key in Set(keys) {
                entries[key, default: []].append(now)
                entries[key] = Array(entries[key, default: []].sorted().suffix(100))
            }
        }
    }

    private func transaction<T>(write: Bool = false, _ body: (inout [String: [Date]]) -> T) -> T {
        lock.withLock {
            var descriptor: Int32 = -1
            var hasFileLock = false
            if let fileURL {
                do {
                    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    descriptor = open(fileURL.path + ".lock", O_CREAT | O_RDWR, 0o600)
                    if descriptor >= 0, flock(descriptor, LOCK_EX) == 0 {
                        hasFileLock = true
                        if FileManager.default.fileExists(atPath: fileURL.path) {
                            entries = try JSONDecoder().decode([String: [Date]].self,
                                                               from: Data(contentsOf: fileURL))
                        }
                    } else {
                        NSLog("Foldwall: cannot lock display history")
                    }
                } catch {
                    NSLog("Foldwall: cannot read display history: %@", error.localizedDescription)
                }
            }
            defer {
                if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) }
            }
            let result = body(&entries)
            if write, hasFileLock, let fileURL {
                do { try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic) }
                catch { NSLog("Foldwall: cannot save display history: %@", error.localizedDescription) }
            }
            return result
        }
    }
}
