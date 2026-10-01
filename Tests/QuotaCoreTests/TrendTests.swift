import Foundation
import QuotaCore

@MainActor func quotaForecastChecks() {
    let now = Date(timeIntervalSince1970: 1_790_500_000)
    func forecast(_ remaining: Double? = 50, rate: Double? = 2, hours: Double? = 20,
                  observed: Double = 1800) -> QuotaForecast {
        QuotaForecast.evaluate(remaining: remaining, resetsAt: hours.map { now.addingTimeInterval($0 * 3600) },
                               pointsPerHour: rate, observedSeconds: observed, now: now)
    }
    expect(forecast(rate: 1.99) == .margin)
    expect(forecast(rate: 2) == .tight) // Exactly 20% of the current remaining quota is left.
    expect(forecast(rate: 2.5) == .tight) // Exactly zero at reset, no reserve.
    expect(forecast(rate: 2.51) == .depletion)
    expect(forecast(rate: 0) == .idle)
    expect(forecast(0, rate: nil, observed: 0) == .exhausted)
    expect(forecast(nil) == .unavailable)
    expect(forecast(-1) == .unavailable)
    expect(forecast(101) == .unavailable)
    expect(forecast(.nan) == .unavailable)
    expect(forecast(rate: nil) == .unavailable)
    expect(forecast(rate: -1) == .unavailable)
    expect(forecast(rate: .nan) == .unavailable)
    expect(forecast(rate: .infinity) == .unavailable)
    expect(forecast(hours: nil) == .unavailable)
    expect(forecast(hours: 0) == .unavailable)
    expect(forecast(hours: -1) == .unavailable)
    expect(forecast(hours: .infinity) == .unavailable)
    expect(forecast(observed: 1799) == .unavailable)
    expect(forecast(observed: .nan) == .unavailable)
    expect(forecast(observed: .infinity) == .unavailable)
    expect(forecast(rate: .greatestFiniteMagnitude) == .depletion)
    // Session and weekly horizons must use their own reset, not the weekly deadline.
    expect(forecast(10, rate: 3, hours: 4) == .depletion)
    expect(forecast(10, rate: 3, hours: 2) == .margin)
    // The yellow reserve is relative to what's left, never 20 points of the original quota.
    expect(forecast(10, rate: 1, hours: 8) == .tight)
    expect(forecast(100, rate: 1, hours: 8) == .margin)
}

@MainActor func quotaTrendChecks() throws {
    let start = Date(timeIntervalSince1970: 1_790_500_000)
    let reset = start.addingTimeInterval(8 * 86400)
    func snapshot(_ minutes: Double, _ remaining: Double?, resetAt: Date? = nil,
                  account: String? = "quota@example.test") -> QuotaSnapshot {
        QuotaSnapshot(provider: .codex, rows: [
            QuotaRow(id: "weekly", title: "Weekly", remaining: remaining, resetsAt: resetAt ?? reset, isWeekly: true)
        ], measuredAt: start.addingTimeInterval(minutes * 60), accountLabel: account)
    }
    func trend(_ history: QuotaTrendHistory, at minutes: Double) -> QuotaTrend? {
        history.trend(for: .codex, rowID: "weekly", now: start.addingTimeInterval(minutes * 60))
    }
    func close(_ value: Double?, _ expected: Double) -> Bool { value.map { abs($0 - expected) < 0.000001 } ?? false }

    var history = QuotaTrendHistory()
    history.record(snapshot(0, 100))
    history.record(snapshot(15, 99))
    expect(trend(history, at: 15) == nil)
    history.record(snapshot(45, 96))
    expect(close(trend(history, at: 45)?.pointsPerHour, 4 / 0.75)) // Time weighted, not mean of rates.
    expect(close(trend(history, at: 45)?.observedSeconds, 2700))
    expect(close(trend(history, at: 45)?.historySeconds, 2700))
    history.record(snapshot(45, 90)) // Duplicate timestamp is ignored.
    history.record(snapshot(40, 90)) // Out-of-order reading is ignored.
    expect(close(trend(history, at: 45)?.pointsPerHour, 4 / 0.75))
    history.record(snapshot(46, 95)) // Frequent opens keep the prior anchor until a useful interval is observed.
    expect(close(trend(history, at: 46)?.observedSeconds, 2700))
    history.record(snapshot(50, 94))
    expect(close(trend(history, at: 50)?.observedSeconds, 3000))
    expect(close(trend(history, at: 50)?.pointsPerHour, 7.2))

    history.interrupt(.codex)
    history.record(snapshot(60, 90))
    expect(close(trend(history, at: 60)?.observedSeconds, 3000)) // Missing time is excluded.
    history.record(snapshot(75, 89))
    expect(close(trend(history, at: 75)?.observedSeconds, 3900))
    history.record(snapshot(120, 70)) // Long gap is excluded; prior intervals survive.
    expect(close(trend(history, at: 120)?.observedSeconds, 3900))
    history.record(snapshot(135, 69))
    expect(close(trend(history, at: 135)?.observedSeconds, 4800))
    history.record(snapshot(150, nil))
    history.record(snapshot(165, 60))
    expect(close(trend(history, at: 165)?.observedSeconds, 4800))
    let newReset = reset.addingTimeInterval(7 * 86400)
    history.record(snapshot(180, 100, resetAt: newReset))
    history.record(snapshot(195, 99, resetAt: newReset))
    expect(close(trend(history, at: 195)?.observedSeconds, 5700)) // Reset is not an interval; old cycle retained.
    history.record(snapshot(210, 100, resetAt: newReset)) // Provider correction/increase is excluded.
    expect(close(trend(history, at: 210)?.observedSeconds, 5700))
    let restored = try JSONDecoder().decode(QuotaTrendHistory.self, from: JSONEncoder().encode(history))
    expect(close(trend(restored, at: 210)?.observedSeconds, 5700))
    let stored = String(data: try JSONEncoder().encode(history), encoding: .utf8)!
    expect(!stored.contains("quota@example.test"))
    history.record(snapshot(225, 50, resetAt: newReset, account: "other@example.test"))
    expect(trend(history, at: 225) == nil)
    history.record(snapshot(240, 49, resetAt: newReset, account: "other@example.test"))
    history.record(snapshot(255, 48, resetAt: newReset, account: "other@example.test"))
    history.record(snapshot(270, 47, resetAt: newReset, account: nil))
    expect(close(trend(history, at: 270)?.observedSeconds, 1800)) // Missing identity preserves the old ledger.
    history.record(snapshot(285, 46, resetAt: newReset, account: "other@example.test"))
    expect(close(trend(history, at: 285)?.observedSeconds, 1800)) // No bridge over unknown identity.

    var spike = QuotaTrendHistory()
    for i in 0...4 { spike.record(snapshot(Double(i * 15), 100 - Double(i))) }
    spike.record(snapshot(75, 90)) // 6 points/15min vs 4pp/h baseline.
    expect(close(trend(spike, at: 75)?.spikePoints, 6))
    expect(close(trend(spike, at: 75)?.spikeSeconds, 900))
    expect(trend(spike, at: 92)?.spikePoints == nil) // No stale alert.
    spike.interrupt(.codex)
    expect(trend(spike, at: 75)?.spikePoints == nil)
    var idle = QuotaTrendHistory()
    for i in 0...4 { idle.record(snapshot(Double(i * 15), 100)) }
    expect(close(trend(idle, at: 60)?.pointsPerHour, 0)) // Observed idle time counts.
    idle.record(snapshot(75, 97))
    expect(close(trend(idle, at: 75)?.spikePoints, 3)) // A zero baseline needs the same absolute threshold.
    var rounded = QuotaTrendHistory()
    for i in 0...4 { rounded.record(snapshot(Double(i * 15), 100)) }
    rounded.record(snapshot(75, 99))
    expect(trend(rounded, at: 75)?.spikePoints == nil) // 1-point rounding noise isn't a spike.

    var shortBaseline = QuotaTrendHistory()
    shortBaseline.record(snapshot(0, 100))
    shortBaseline.record(snapshot(15, 99))
    shortBaseline.record(snapshot(30, 98))
    shortBaseline.record(snapshot(45, 94))
    expect(close(trend(shortBaseline, at: 45)?.spikePoints, 4)) // 30 minutes suffice.
    var exactThreshold = QuotaTrendHistory()
    exactThreshold.record(snapshot(0, 100))
    exactThreshold.record(snapshot(15, 99))
    exactThreshold.record(snapshot(30, 98))
    exactThreshold.record(snapshot(45, 95))
    expect(trend(exactThreshold, at: 45)?.spikePoints == nil) // Strictly above 3x.
    exactThreshold.record(snapshot(60, 100, resetAt: newReset))
    exactThreshold.record(snapshot(75, 95, resetAt: newReset))
    expect(trend(exactThreshold, at: 75)?.spikePoints == nil) // Previous cycle is not the spike baseline.

    // Seven calendar days retain measured intervals across gaps and cycles; old data expires.
    var rolling = QuotaTrendHistory()
    rolling.record(snapshot(0, 100))
    rolling.record(snapshot(15, 99))
    rolling.record(snapshot(30, 98))
    let sevenDays = 7.0 * 24 * 60
    rolling.record(snapshot(sevenDays - 15, 80))
    rolling.record(snapshot(sevenDays, 78))
    rolling.record(snapshot(sevenDays + 15, 76))
    expect(close(trend(rolling, at: sevenDays + 15)?.observedSeconds, 2700))
    expect(close(trend(rolling, at: sevenDays + 15)?.pointsPerHour, 5 / 0.75))
    expect(close(trend(rolling, at: sevenDays + 15)?.historySeconds, 7 * 86400))
    expect(close(trend(rolling, at: sevenDays + 22.5)?.observedSeconds, 2250)) // Cut boundary proportionally.
    rolling.prune(now: start.addingTimeInterval(15 * 86400))
    expect(trend(rolling, at: 15 * 1440) == nil)
}
