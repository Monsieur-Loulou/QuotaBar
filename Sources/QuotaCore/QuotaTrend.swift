import Foundation
import CryptoKit

public struct QuotaTrend: Sendable {
    /// Percentage points consumed per hour, weighted by observed time.
    public let pointsPerHour: Double
    public let observedSeconds: TimeInterval
    public let historySeconds: TimeInterval
    public let spikePoints: Double?
    public let spikeSeconds: TimeInterval?
}

/// A conditional projection: the observed hourly rate continues until the current reset.
public enum QuotaForecast: Sendable {
    case margin, tight, depletion, exhausted, idle, unavailable

    public static func evaluate(remaining: Double?, resetsAt: Date?, pointsPerHour: Double?,
                                observedSeconds: TimeInterval, now: Date) -> Self {
        guard let remaining, remaining.isFinite, (0...100).contains(remaining),
              let resetsAt, resetsAt.timeIntervalSince(now).isFinite, resetsAt > now else { return .unavailable }
        if remaining == 0 { return .exhausted }
        guard let pointsPerHour, pointsPerHour.isFinite, pointsPerHour >= 0,
              observedSeconds.isFinite, observedSeconds >= 30 * 60 else { return .unavailable }
        // A quiet observation period cannot establish a sustainable future rate.
        if pointsPerHour == 0 { return .idle }
        let projected = pointsPerHour * (resetsAt.timeIntervalSince(now) / 3600)
        if projected > remaining { return .depletion }
        // Yellow includes an exact match: reaching zero at reset leaves no reserve.
        return projected >= remaining * 0.8 ? .tight : .margin
    }
}

/// A bounded, local ledger of measured intervals. Missing time is never counted as idle time.
public struct QuotaTrendHistory: Codable, Sendable {
    public static let retention: TimeInterval = 7 * 86400
    private static let minimumInterval: TimeInterval = 5 * 60
    private static let maximumInterval: TimeInterval = 30 * 60
    private var providers: [String: ProviderHistory] = [:]

    public init() {}

    public mutating func record(_ snapshot: QuotaSnapshot) {
        let key = snapshot.provider.rawValue
        // Without an account identity, observations cannot be safely joined across refreshes.
        guard let account = snapshot.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty else {
            interrupt(snapshot.provider)
            return
        }
        let accountID = SHA256.hash(data: Data(account.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        var history = providers[key].flatMap { $0.accountID == accountID ? $0 : nil }
            ?? ProviderHistory(accountID: accountID)
        guard history.lastRead.map({ snapshot.measuredAt > $0 }) ?? true else { return }
        history.lastRead = snapshot.measuredAt
        let presentIDs = Set(snapshot.rows.map(\.id))
        for id in history.rows.keys where !presentIDs.contains(id) { history.rows[id]?.anchor = nil }
        for row in snapshot.rows {
            var series = history.rows[row.id] ?? Series(startedAt: snapshot.measuredAt)
            series.prune(now: snapshot.measuredAt)
            guard let remaining = row.remaining, remaining.isFinite, (0...100).contains(remaining),
                  let reset = row.resetsAt, reset > snapshot.measuredAt else {
                series.anchor = nil
                history.rows[row.id] = series
                continue
            }
            let next = Sample(at: snapshot.measuredAt, remaining: remaining, reset: reset, title: row.title)
            if let previous = series.anchor {
                let duration = next.at.timeIntervalSince(previous.at)
                let sameCycle = abs(reset.timeIntervalSince(previous.reset)) < 1 && row.title == previous.title
                if sameCycle && previous.reset > next.at && remaining <= previous.remaining && duration <= Self.maximumInterval {
                    // Frequent panel opens do not turn rounded quota percentages into misleading bursts.
                    if duration < Self.minimumInterval { history.rows[row.id] = series; continue }
                    series.intervals.append(Interval(start: previous.at, end: next.at,
                                                     points: previous.remaining - remaining, reset: reset, title: row.title))
                }
            }
            series.anchor = next
            history.rows[row.id] = series
        }
        // Absent rows retain their measured intervals until the retention window expires.
        for id in history.rows.keys {
            history.rows[id]?.prune(now: snapshot.measuredAt)
            if history.rows[id]?.intervals.isEmpty == true && !presentIDs.contains(id) { history.rows[id] = nil }
        }
        providers[key] = history
    }

    public mutating func interrupt(_ provider: Provider) {
        guard var history = providers[provider.rawValue] else { return }
        for id in history.rows.keys { history.rows[id]?.anchor = nil }
        providers[provider.rawValue] = history
    }

    public func trend(for provider: Provider, rowID: String, now: Date) -> QuotaTrend? {
        guard let series = providers[provider.rawValue]?.rows[rowID] else { return nil }
        let cutoff = now.addingTimeInterval(-Self.retention)
        let intervals = series.intervals.compactMap { $0.clipped(from: cutoff, to: now) }
        let duration = intervals.reduce(0) { $0 + $1.duration }
        guard intervals.count >= 2, duration >= 30 * 60 else { return nil }
        let rate = intervals.reduce(0) { $0 + $1.points } / duration * 3600
        var spike: Interval?
        if let latest = intervals.last, now.timeIntervalSince(latest.end) <= 16 * 60,
           let anchor = series.anchor, anchor.at == latest.end, anchor.reset == latest.reset {
            let baselineStart = latest.start.addingTimeInterval(-2 * 3600)
            let baseline = intervals.dropLast().filter { $0.reset == latest.reset && $0.title == latest.title }
                .compactMap { $0.clipped(from: baselineStart, to: latest.start) }
            let baselineTime = baseline.reduce(0) { $0 + $1.duration }
            if baseline.count >= 2, baselineTime >= 30 * 60 {
                let baselineRate = baseline.reduce(0) { $0 + $1.points } / baselineTime * 3600
                let latestRate = latest.points / latest.duration * 3600
                if latest.points >= 3 && latestRate > baselineRate * 3 { spike = latest }
            }
        }
        return QuotaTrend(pointsPerHour: rate, observedSeconds: duration,
                          historySeconds: min(Self.retention, max(0, now.timeIntervalSince(series.startedAt))),
                          spikePoints: spike?.points, spikeSeconds: spike?.duration)
    }

    public mutating func prune(now: Date) {
        for provider in providers.keys {
            guard var history = providers[provider] else { continue }
            for id in history.rows.keys {
                history.rows[id]?.prune(now: now)
                if history.rows[id]?.intervals.isEmpty == true && history.rows[id]?.anchor == nil { history.rows[id] = nil }
            }
            if history.rows.isEmpty { providers[provider] = nil } else { providers[provider] = history }
        }
    }

    private struct ProviderHistory: Codable, Sendable {
        let accountID: String
        var lastRead: Date?
        var rows: [String: Series] = [:]
    }
    private struct Sample: Codable, Sendable {
        let at: Date
        let remaining: Double
        let reset: Date
        let title: String
    }
    private struct Series: Codable, Sendable {
        let startedAt: Date
        var anchor: Sample?
        var intervals: [Interval] = []
        mutating func prune(now: Date) {
            let cutoff = now.addingTimeInterval(-QuotaTrendHistory.retention)
            intervals = intervals.compactMap { $0.clipped(from: cutoff, to: now) }
            if let sample = anchor, now.timeIntervalSince(sample.at) > QuotaTrendHistory.maximumInterval || sample.at > now {
                anchor = nil
            }
        }
    }
    private struct Interval: Codable, Sendable {
        let start: Date
        let end: Date
        let points: Double
        let reset: Date
        let title: String
        var duration: TimeInterval { end.timeIntervalSince(start) }
        func clipped(from lower: Date, to upper: Date) -> Interval? {
            let from = max(start, lower), to = min(end, upper)
            guard to > from, duration > 0, points.isFinite, points >= 0 else { return nil }
            return Interval(start: from, end: to, points: points * to.timeIntervalSince(from) / duration,
                            reset: reset, title: title)
        }
    }
}
