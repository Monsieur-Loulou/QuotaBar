import Foundation
import Darwin
import QuotaCore

@MainActor enum Checks {
    static var failures: [String] = []
    static var assertions = 0
}
@MainActor func expect(_ condition: @autoclosure () -> Bool, file: String = #fileID, line: Int = #line) {
    Checks.assertions += 1
    if !condition() { Checks.failures.append("\(file):\(line): assertion failed") }
}
@MainActor func expectThrows<T>(_ expected: QuotaError, file: String = #fileID, line: Int = #line, body: () throws -> T) {
    do { _ = try body(); Checks.failures.append("\(file):\(line): expected \(expected)") }
    catch { expect((error as? QuotaError) == expected, file: file, line: line) }
}
@MainActor func expectThrows<T>(_ expected: QuotaError, file: String = #fileID, line: Int = #line, body: () async throws -> T) async {
    do { _ = try await body(); Checks.failures.append("\(file):\(line): expected \(expected)") }
    catch { expect((error as? QuotaError) == expected, file: file, line: line) }
}

private let now = Date(timeIntervalSince1970: 1_790_597_000)
private func json(_ text: String) -> Data { Data(text.utf8) }
private let codexAccount = json(#"{"account":{"type":"chatgpt","email":"example@example.test","planType":"pro"}}"#)

@MainActor func codexWeeklyUsesItsActualWindowNotPrimaryPosition() throws {
    let value = try QuotaDecoder.codex(account: codexAccount, limits: json("""
    {"rateLimits":{"primary":{"usedPercent":60,"windowDurationMins":300,"resetsAt":1790600000},
    "secondary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1791000000}}}
    """), now: now)
    expect(value.weekly?.remaining == 98)
    expect(value.weekly?.resetsAt == Date(timeIntervalSince1970: 1_791_000_000))
    expect(value.rows.first?.title == "Session · 5 heures")
    expect(value.accountLabel == "example@example.test")
    expect(value.measuredAt == now)
    expect(value.menuValue(now: now, failed: false) == "98%")
}

@MainActor func codexPrimaryCanBeWeeklyAndMissingIsNotOneHundred() throws {
    let value = try QuotaDecoder.codex(account: codexAccount, limits: json("""
    {"rateLimits":{"primary":{"usedPercent":61,"windowDurationMins":10080,"resetsAt":1791637613},"secondary":null}}
    """), now: now)
    expect(value.weekly?.remaining == 39)
    expect(value.rows.count == 1)
    let missing = try QuotaDecoder.codex(account: codexAccount, limits: json("""
    {"rateLimits":{"primary":{"windowDurationMins":10080}}}
    """), now: now)
    expect(missing.weekly?.remaining == nil)
    expect(missing.menuValue(now: now, failed: false) == "--")
}

@MainActor func codexSignedOutAndInvalidAnswers() {
    expectThrows(QuotaError.codexSignedOut) {
        try QuotaDecoder.codex(account: json(#"{"account":null}"#), limits: json(#"{"rateLimits":null}"#), now: now)
    }
    expectThrows(QuotaError.unavailable) {
        try QuotaDecoder.codex(account: codexAccount, limits: json(#"{"rateLimits":null}"#), now: now)
    }
    expectThrows(QuotaError.invalidResponse) {
        try QuotaDecoder.codex(account: codexAccount, limits: json(#"{"rateLimits":{"primary":{"usedPercent":-2}}}"#), now: now)
    }
    expectThrows(QuotaError.invalidResponse) { try QuotaDecoder.codex(account: json("not json"), limits: json("{}"), now: now) }
}

@MainActor func claudeOfficialUsageKeepsModelLimitsSeparate() throws {
    let value = try QuotaDecoder.claude(usage: json("""
    {"five_hour":{"utilization":10.0,"resets_at":"2026-10-06T08:30:00.182638+00:00"},
    "seven_day":{"utilization":49.0,"resets_at":"2026-10-12T06:00:00+00:00"},
    "seven_day_sonnet":{"utilization":12.5,"resets_at":null},"seven_day_opus":null,
    "iguana_necktie":{"utilization":0.25},"extra_usage":{"is_enabled":false}}
    """), profile: json(#"{"account":{"email":"example@example.test"}}"#), now: now)
    expect(value.weekly?.remaining == 51)
    expect(value.weekly?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-12T06:00:00Z"))
    expect(value.rows.map(\.title) == ["Session · 5 heures", "Hebdomadaire", "Sonnet · hebdomadaire"])
    expect(value.rows.last?.isWeekly == false)
    expect(value.accountLabel == "example@example.test")
    let modelOnly = try QuotaDecoder.claude(usage: json(#"{"seven_day_sonnet":{"utilization":10}}"#), profile: nil, now: now)
    expect(modelOnly.weekly == nil)
    expect(modelOnly.accountLabel == nil)
    expect(modelOnly.menuValue(now: now, failed: false) == "--")
    expectThrows(QuotaError.unavailable) { try QuotaDecoder.claude(usage: json("{}"), profile: nil, now: now) }
    expectThrows(QuotaError.invalidResponse) {
        try QuotaDecoder.claude(usage: json(#"{"seven_day":{"utilization":-1}}"#), profile: nil, now: now)
    }
}

@MainActor func staleFailedAndResetSnapshotsNeverLookFreshInTheBar() throws {
    let value = try QuotaDecoder.codex(account: codexAccount, limits: json("""
    {"rateLimits":{"primary":{"usedPercent":2,"windowDurationMins":10080}}}
    """), now: now)
    expect(value.menuValue(now: now, failed: true) == "--")
    expect(value.menuValue(now: now.addingTimeInterval(961), failed: false) == "--")
    let expired = QuotaSnapshot(provider: .codex, rows: [
        QuotaRow(id: "weekly", title: "Weekly", remaining: 98, resetsAt: now, isWeekly: true)
    ], measuredAt: now)
    expect(expired.menuValue(now: now, failed: false) == "--")
}

/// A stand-in for `codex app-server`: answers only once it has read the rate-limit request,
/// then waits for its stdin to close, like the real server.
private func fakeServer(_ body: String) throws -> (URL, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quota-server-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let server = folder.appendingPathComponent("codex")
    try Data(("#!/bin/sh\n[ \"$1\" = app-server ] || exit 2\n" + body).utf8).write(to: server)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
    return (folder, server)
}

@MainActor func codexServerKeepsStdinOpenUntilBothAnswers() async throws {
    let (folder, server) = try fakeServer(#"""
    while read -r line; do
      case "$line" in
        *'"id":1'*) echo '{"id":1,"result":{}}'; echo '{"method":"remoteControl/status/changed","params":{}}' ;;
        *'"refreshToken":false'*) echo '{"id":2,"result":{"account":{"email":"example@example.test"}}}' ;;
        *'"id":2'*) exit 3 ;;
        *'rateLimits/read'*) { sleep 0.3; echo '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":10080}}}}'; } & pending=$! ;;
      esac
    done
    # Like the real server: end of input drops an answer still in progress.
    kill "$pending" 2>/dev/null
    echo closed > "$(dirname "$0")/closed"
    """#)
    defer { try? FileManager.default.removeItem(at: folder) }
    let answers = try await CodexAppServer.request(path: server.path, timeout: 5)
    let value = try QuotaDecoder.codex(account: answers.account, limits: answers.limits, now: now)
    expect(value.weekly?.remaining == 95)
    let deadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("closed").path), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("closed").path))
}

@MainActor func codexServerFailuresAreBounded() async throws {
    let (silentFolder, silent) = try fakeServer("cat > /dev/null\n")
    defer { try? FileManager.default.removeItem(at: silentFolder) }
    let started = Date()
    await expectThrows(QuotaError.timeout) { try await CodexAppServer.request(path: silent.path, timeout: 0.3) }
    expect(Date().timeIntervalSince(started) < 2)
    let (earlyFolder, early) = try fakeServer("exit 0\n")
    defer { try? FileManager.default.removeItem(at: earlyFolder) }
    await expectThrows(QuotaError.unavailable) { try await CodexAppServer.request(path: early.path, timeout: 5) }
    let (signedOutFolder, signedOut) = try fakeServer(#"""
    while read -r line; do case "$line" in *'"id":2'*) echo '{"id":2,"error":{"code":-32600}}' ;; esac; done
    """#)
    defer { try? FileManager.default.removeItem(at: signedOutFolder) }
    await expectThrows(QuotaError.codexSignedOut) { try await CodexAppServer.request(path: signedOut.path, timeout: 5) }
    let task = Task { try await CodexAppServer.request(path: silent.path, timeout: 30) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await expectThrows(QuotaError.cancelled) { try await task.value }
    await expectThrows(QuotaError.codexMissing) { try await QuotaReader(codexPath: nil).fetch(.codex) }
}

@MainActor func automaticQuarterHourAndPanelAlwaysForcesFreshRead() {
    var policy = RefreshPolicy()
    expect(policy.begin(now: now, force: false))
    expect(!policy.begin(now: now, force: true)) // coalesces while already fetching
    policy.finish()
    expect(!policy.begin(now: now.addingTimeInterval(899), force: false))
    expect(policy.begin(now: now.addingTimeInterval(900), force: false))
    policy.finish()
    expect(policy.begin(now: now.addingTimeInterval(901), force: true))
    expect(policy.nextAutomatic == now.addingTimeInterval(1801))
}

@MainActor func refreshModesPreserveExplicitActionsAndReconfigureTimers() {
    for mode in RefreshMode.allCases {
        var policy = RefreshPolicy(mode: mode)
        expect(policy.begin(now: now, force: true)) // One launch read in every mode.
        expect(!policy.begin(now: now, force: true))
        policy.finish()
        if let interval = mode.interval {
            expect(!policy.begin(now: now.addingTimeInterval(interval - 1), force: false))
            expect(policy.begin(now: now.addingTimeInterval(interval), force: false))
        } else {
            expect(policy.nextAutomatic == nil)
            expect(!policy.begin(now: now.addingTimeInterval(86400), force: false))
            expect(policy.begin(now: now.addingTimeInterval(86400), force: true))
        }
    }
    var policy = RefreshPolicy()
    expect(policy.begin(now: now, force: true))
    policy.setMode(.onOpen, now: now.addingTimeInterval(10)) // Switch to on-open mode while fetching.
    expect(policy.running && policy.nextAutomatic == nil)
    policy.finish()
    expect(!policy.begin(now: now.addingTimeInterval(1000), force: false))
    policy.setMode(.oneMinute, now: now.addingTimeInterval(1000))
    expect(policy.nextAutomatic == now.addingTimeInterval(1060))
    expect(!policy.begin(now: now.addingTimeInterval(1059), force: false))
    expect(policy.begin(now: now.addingTimeInterval(1060), force: false))
    policy.finish()
    policy.setMode(.thirtyMinutes, now: now.addingTimeInterval(1100))
    expect(policy.nextAutomatic == now.addingTimeInterval(2900))
    for mode in [RefreshMode.onOpen] {
        var onOpen = RefreshPolicy(mode: mode)
        expect(onOpen.begin(now: now, force: true))
        onOpen.sleep()
        onOpen.wake()
        expect(!onOpen.begin(now: now.addingTimeInterval(4000), force: false))
        expect(onOpen.begin(now: now.addingTimeInterval(4000), force: true))
    }
    let reset = now.addingTimeInterval(7200)
    let snapshot = QuotaSnapshot(provider: .codex, rows: [
        QuotaRow(id: "weekly", title: "Hebdomadaire", remaining: 41, resetsAt: reset, isWeekly: true)
    ], measuredAt: now)
    expect(snapshot.menuValue(now: now.addingTimeInterval(1200), failed: false) == "--")
    expect(snapshot.menuValue(now: now.addingTimeInterval(1200), failed: false,
        freshnessInterval: RefreshMode.thirtyMinutes.freshnessInterval) == "41%")
    expect(snapshot.menuValue(now: now.addingTimeInterval(1861), failed: false,
        freshnessInterval: RefreshMode.thirtyMinutes.freshnessInterval) == "--")
    expect(snapshot.displayExpiry(freshnessInterval: RefreshMode.thirtyMinutes.freshnessInterval) == now.addingTimeInterval(1861))
    let earlyReset = QuotaSnapshot(provider: .codex, rows: [
        QuotaRow(id: "weekly", title: "Hebdomadaire", remaining: 41, resetsAt: now.addingTimeInterval(100), isWeekly: true)
    ], measuredAt: now)
    expect(earlyReset.displayExpiry(freshnessInterval: 1860) == now.addingTimeInterval(101))
}

@MainActor func sleepAndWakeDoNotCatchUpMissedRefreshes() {
    var policy = RefreshPolicy()
    expect(policy.begin(now: now, force: false))
    policy.sleep()
    expect(!policy.begin(now: now.addingTimeInterval(4000), force: true))
    policy.wake()
    expect(policy.begin(now: now.addingTimeInterval(4000), force: false))
    policy.finish()
    expect(!policy.begin(now: now.addingTimeInterval(4001), force: false))
}

@MainActor func shortSleepResumesOnlyAnInterruptedRefresh() {
    var interrupted = RefreshPolicy()
    expect(interrupted.begin(now: now, force: false))
    interrupted.sleep()
    interrupted.wake()
    expect(interrupted.begin(now: now.addingTimeInterval(30), force: false))
    expect(interrupted.nextAutomatic == now.addingTimeInterval(930))

    var completed = RefreshPolicy()
    expect(completed.begin(now: now, force: false))
    completed.finish()
    completed.sleep()
    completed.wake()
    expect(!completed.begin(now: now.addingTimeInterval(30), force: false))
    expect(completed.nextAutomatic == now.addingTimeInterval(900))
}

@MainActor func subprocessHasBoundedOutputAndTime() async throws {
    let value = try await BoundedProcess.run(path: "/usr/bin/printf", arguments: ["hello"], environment: [:])
    expect(String(data: value.data, encoding: .utf8) == "hello")
    expect(value.exitStatus == 0)
    await expectThrows(QuotaError.oversizedOutput) {
        try await BoundedProcess.run(path: "/usr/bin/printf", arguments: ["too much"], environment: [:], capacity: 3)
    }
    await expectThrows(QuotaError.timeout) {
        try await BoundedProcess.run(path: "/bin/sh", arguments: ["-c", "sleep 10 & wait"], environment: [:], timeout: 0.1)
    }
}

@MainActor func cancellationStopsAWholeFetch() async {
    let task = Task {
        try await BoundedProcess.run(path: "/bin/sleep", arguments: ["10"], environment: [:])
    }
    task.cancel()
    await expectThrows(QuotaError.cancelled) { try await task.value }
}

@MainActor func cancellationReapsRunningHelperAndItsChild() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quota-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let marker = folder.appendingPathComponent("child.pid")
    let task = Task {
        try await BoundedProcess.run(path: "/bin/sh", arguments: [
            "-c", "sleep 20 & printf '%s' \"$!\" > \"$1\"; wait", "quota-check", marker.path,
        ], environment: [:])
    }
    let startedDeadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: marker.path), Date() < startedDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    let child = (try? String(contentsOf: marker, encoding: .utf8)).flatMap(Int32.init)
    task.cancel()
    await expectThrows(QuotaError.cancelled) { try await task.value }
    expect(child != nil)
    if let child {
        let stoppedDeadline = Date().addingTimeInterval(2)
        while kill(child, 0) == 0, Date() < stoppedDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        expect(kill(child, 0) == -1 && errno == ESRCH)
    }
}

@MainActor func displayModesAndAbsoluteResetDates() {
    expect(QuotaDisplayMode.remaining.percentage(41.9) == 41)
    expect(QuotaDisplayMode.used.percentage(41.9) == 58)
    expect(QuotaDisplayMode.used.percentage(0) == 100)
    expect(QuotaDisplayMode.used.percentage(100) == 0)
    expect(QuotaDisplayMode.used.percentage(nil) == nil)
    expect(QuotaDisplayMode.used.percentage(.nan) == nil)
    let snapshot = QuotaSnapshot(provider: .codex, rows: [
        QuotaRow(id: "weekly", title: "Hebdomadaire", remaining: 41, resetsAt: now.addingTimeInterval(3600), isWeekly: true)
    ], measuredAt: now)
    expect(snapshot.menuValue(now: now, failed: false, mode: .used) == "59%")
    expect(snapshot.menuValue(now: now, failed: true, mode: .used) == "--")
    let date = ISO8601DateFormatter().date(from: "2026-10-03T16:30:00Z")!
    let label = QuotaResetLabel.text(date, now: date.addingTimeInterval(-60), timeZone: TimeZone(identifier: "Europe/Paris")!)
    expect(label.contains("sam.") && label.contains("3 oct.") && label.contains("18:30"))
    expect(!label.contains("attente"))
    expect(QuotaResetLabel.text(date, now: date, timeZone: TimeZone(secondsFromGMT: 0)!).contains("attente"))
}

@MainActor func firstLaunchReadAuthorization() {
    let now = Date(timeIntervalSince1970: 1_790_500_000)
    for mode in RefreshMode.allCases {
        var policy = RefreshPolicy(mode: mode)
        policy.setReadAuthorization(false)
        expect(!policy.begin(now: now, force: true))
        expect(!policy.begin(now: now, force: false))
        policy.setMode(.oneMinute, now: now)
        expect(policy.nextAutomatic == nil)
        policy.sleep()
        policy.wake()
        expect(!policy.begin(now: now.addingTimeInterval(86400), force: false))
        policy.setReadAuthorization(true)
        expect(policy.begin(now: now, force: true))
        policy.finish()
        policy.setReadAuthorization(false)
        expect(policy.nextAutomatic == nil)
        expect(!policy.begin(now: now.addingTimeInterval(86400), force: false))
    }
}

@main @MainActor struct QuotaCoreCheckRunner {
static func main() async {
    do {
        firstLaunchReadAuthorization()
        displayModesAndAbsoluteResetDates()
        try quotaTrendChecks()
        quotaForecastChecks()
        try codexWeeklyUsesItsActualWindowNotPrimaryPosition()
        try codexPrimaryCanBeWeeklyAndMissingIsNotOneHundred()
        codexSignedOutAndInvalidAnswers()
        try claudeOfficialUsageKeepsModelLimitsSeparate()
        try staleFailedAndResetSnapshotsNeverLookFreshInTheBar()
        try await codexServerKeepsStdinOpenUntilBothAnswers()
        try await codexServerFailuresAreBounded()
        automaticQuarterHourAndPanelAlwaysForcesFreshRead()
        refreshModesPreserveExplicitActionsAndReconfigureTimers()
        sleepAndWakeDoNotCatchUpMissedRefreshes()
        shortSleepResumesOnlyAnInterruptedRefresh()
        try await subprocessHasBoundedOutputAndTime()
        await cancellationStopsAWholeFetch()
        try await cancellationReapsRunningHelperAndItsChild()
    } catch { Checks.failures.append("Unexpected error: \(error)") }
    for failure in Checks.failures { print("FAIL: \(failure)") }
    print("\(Checks.assertions) assertions, \(Checks.failures.count) failures")
    exit(Checks.failures.isEmpty ? 0 : 1)
}
}
