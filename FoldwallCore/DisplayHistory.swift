import Foundation
import Darwin

/// Unit of the rolling window. Months are calendar months, not 30-day blocks.
public enum RepeatWindowUnit: String, Codable, Sendable, CaseIterable {
    case hour, day, week, month

    public var range: ClosedRange<Int> {
        switch self {
        case .hour: 1...720
        case .day: 1...365
        case .week: 1...52
        case .month: 1...12
        }
    }

    var component: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }
}

/// A rolling window shared by image draws and shuffled videos. Limits are also the
/// history retention bounds, so increasing a setting can use earlier observations.
public struct DisplayRepeatPolicy: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var amount: Int { didSet { amount = unit.range.clamp(amount) } }
    /// Switching units keeps the number and only clamps it into the new unit's range.
    public var unit: RepeatWindowUnit { didSet { amount = unit.range.clamp(amount) } }
    public var maxDisplays: Int { didSet { maxDisplays = Self.countRange.clamp(maxDisplays) } }
    public static let countRange = 1...100
    /// The longest possible window (12 months / 365 days); history older than this is dropped.
    public static let retention: TimeInterval = 366 * 86_400

    public init(isEnabled: Bool = true, amount: Int = 1, unit: RepeatWindowUnit = .day,
                maxDisplays: Int = 1) {
        self.isEnabled = isEnabled
        self.unit = unit
        self.amount = unit.range.clamp(amount)
        self.maxDisplays = Self.countRange.clamp(maxDisplays)
    }

    // `hours` is the pre-0.13 format; still written so older builds reading a backup
    // get the closest window they can express.
    private enum CodingKeys: String, CodingKey { case isEnabled, amount, unit, maxDisplays, hours }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let maxDisplays = try values.decodeIfPresent(Int.self, forKey: .maxDisplays) ?? 1
        if let amount = try values.decodeIfPresent(Int.self, forKey: .amount) {
            let unit = (try? values.decodeIfPresent(RepeatWindowUnit.self, forKey: .unit)) ?? .hour
            self.init(isEnabled: isEnabled, amount: amount, unit: unit, maxDisplays: maxDisplays)
        } else if let hours = try values.decodeIfPresent(Int.self, forKey: .hours) {
            self.init(isEnabled: isEnabled, amount: hours, unit: .hour, maxDisplays: maxDisplays)
        } else {
            self.init(isEnabled: isEnabled, maxDisplays: maxDisplays)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(amount, forKey: .amount)
        try values.encode(unit, forKey: .unit)
        try values.encode(maxDisplays, forKey: .maxDisplays)
        let hours = Date.now.timeIntervalSince(cutoff(before: .now)) / 3600
        try values.encode(min(max(Int(hours.rounded()), 1), 720), forKey: .hours)
    }

    /// Displays after this instant count toward the limit.
    public func cutoff(before now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: unit.component, value: -unit.range.clamp(amount), to: now)
            ?? now.addingTimeInterval(-Self.retention)
    }

    public var limit: Int { Self.countRange.clamp(maxDisplays) }
}

extension ClosedRange where Bound == Int {
    func clamp(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
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
            let cutoff = policy.cutoff(before: now)
            return Set(entries.compactMap { key, dates in
                dates.filter { $0 > cutoff }.count >= policy.limit ? key : nil
            })
        }
    }

    public func record(_ keys: [String], now: Date = .now) {
        guard !keys.isEmpty else { return }
        transaction(write: true) { entries in
            let cutoff = now.addingTimeInterval(-DisplayRepeatPolicy.retention)
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
