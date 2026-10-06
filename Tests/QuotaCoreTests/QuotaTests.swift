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
private func payload(_ usage: String, provider: String = "codex", source: String = "oauth") -> Data {
    Data("""
    [{"provider":"\(provider)","source":"\(source)","usage":{
    "updatedAt":"\(ISO8601DateFormatter().string(from: now))",\(usage)}}]
    """.utf8)
}

@MainActor func weeklyUsesItsActualWindowNotPrimaryPosition() throws {
    let value = try QuotaDecoder.decode(payload("""
    "primary":{"usedPercent":60,"windowMinutes":300},
    "secondary":{"usedPercent":2,"windowMinutes":10080},
    "extraRateWindows":[{"id":"fable","title":"Fable only","window":{"usedPercent":10},"usageKnown":true}]
    """), for: .codex, now: now)
    expect(value.weekly?.remaining == 98)
    expect(value.rows.count == 3)
    expect(value.menuValue(now: now, failed: false) == "98%")
}

@MainActor func primaryCanBeWeeklyAndMissingIsNotOneHundred() throws {
    let value = try QuotaDecoder.decode(payload("""
    "primary":{"usedPercent":5,"windowMinutes":10080}
    """), for: .codex, now: now)
    expect(value.weekly?.remaining == 95)
    let missing = try QuotaDecoder.decode(payload("""
    "secondary":{"windowMinutes":10080}
    """), for: .codex, now: now)
    expect(missing.weekly?.remaining == nil)
    expect(missing.menuValue(now: now, failed: false) == "--")
}

@MainActor func modelWeeklyIsNotTheOverallWeeklyQuota() throws {
    let raw = """
    [{"provider":"claude","source":"web","rateWindowLabels":{"tertiary":"Sonnet"},
    "usage":{"updatedAt":"\(ISO8601DateFormatter().string(from: now))",
    "tertiary":{"usedPercent":10,"windowMinutes":10080}}}]
    """
    let value = try QuotaDecoder.decode(Data(raw.utf8), for: .claude, now: now)
    expect(value.weekly == nil)
    expect(value.rows.first?.title == "Sonnet")
    expect(value.menuValue(now: now, failed: false) == "--")
}

@MainActor func sourceIdentityIsPreservedAndCannotCrossProviders() throws {
    let value = try QuotaDecoder.decode(payload("""
    "identity":{"providerID":"codex","accountEmail":"example@example.test"},
    "secondary":{"usedPercent":10,"windowMinutes":10080}
    """), for: .codex, now: now)
    expect(value.accountLabel == "example@example.test")
    expectThrows(QuotaError.invalidResponse) {
        try QuotaDecoder.decode(payload("""
        "identity":{"providerID":"claude","accountEmail":"example@example.test"},
        "secondary":{"usedPercent":10,"windowMinutes":10080}
        """), for: .codex, now: now)
    }
}

@MainActor func claudeDirectHTTPIncludesItsModelWindows() throws {
    let value = try QuotaDecoder.decode(payload("""
    "primary":{"usedPercent":1,"windowMinutes":300},
    "secondary":{"usedPercent":0,"windowMinutes":10080},
    "extraRateWindows":[{"id":"fable","title":"Fable only","window":{"usedPercent":0,"windowMinutes":10080}}]
    """, provider: "claude", source: "web"), for: .claude, now: now)
    expect(value.weekly?.remaining == 100)
    expect(value.rows.last?.title == "Fable only")
}

@MainActor func syntheticAndUnknownWindowsCannotInventQuotas() throws {
    let value = try QuotaDecoder.decode(payload("""
    "primary":{"usedPercent":0,"windowMinutes":300,"isSyntheticPlaceholder":true},
    "secondary":{"usedPercent":100,"windowMinutes":10080},
    "extraRateWindows":[{"id":"future","title":"Future","usageKnown":false,"window":{"usedPercent":0}}]
    """), for: .codex, now: now)
    expect(value.rows.count == 2)
    expect(value.weekly?.remaining == 0)
    expect(value.rows.last?.remaining == nil)
}

@MainActor func staleFailedAndResetSnapshotsNeverLookFreshInTheBar() throws {
    let value = try QuotaDecoder.decode(payload("""
    "secondary":{"usedPercent":2,"windowMinutes":10080}
    """), for: .codex, now: now)
    expect(value.menuValue(now: now, failed: true) == "--")
    expect(value.menuValue(now: now.addingTimeInterval(961), failed: false) == "--")
    let expired = QuotaSnapshot(provider: .codex, rows: [
        QuotaRow(id: "weekly", title: "Weekly", remaining: 98, resetsAt: now, isWeekly: true)
    ], measuredAt: now)
    expect(expired.menuValue(now: now, failed: false) == "--")
}

@MainActor func rejectsUnexpectedOrAmbiguousSources() {
    expectThrows(QuotaError.unsupportedSource) {
        try QuotaDecoder.decode(payload("\"secondary\":{\"usedPercent\":2}", source: "openai-web"), for: .codex, now: now)
    }
    expectThrows(QuotaError.invalidResponse) {
        try QuotaDecoder.decode(payload("\"secondary\":{\"usedPercent\":-2}"), for: .codex, now: now)
    }
    let single = String(data: payload("\"secondary\":{\"usedPercent\":2}"), encoding: .utf8)!
    let two = "[" + single.dropFirst().dropLast() + "," + single.dropFirst().dropLast() + "]"
    expectThrows(QuotaError.multipleAccounts) {
        try QuotaDecoder.decode(Data(two.utf8), for: .codex, now: now)
    }
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

@MainActor func readerMustStayInsideTheApp() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quota-reader-check-" + UUID().uuidString)
    let app = folder.appendingPathComponent("Moved QuotaBar.app")
    let helper = app.appendingPathComponent("Contents/Helpers/CodexBarCLI")
    try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    // A missing reader never falls back to the installed CodexBar on this Mac.
    expect(HelperReader.bundledHelper(in: app) == nil)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: helper.path)
    expect(HelperReader.bundledHelper(in: app) == nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    expect(HelperReader.bundledHelper(in: app) == helper.resolvingSymlinksInPath().path)
    let moved = folder.appendingPathComponent("Another location.app")
    try FileManager.default.moveItem(at: app, to: moved)
    expect(HelperReader.bundledHelper(in: moved) != nil)
    let movedHelper = moved.appendingPathComponent("Contents/Helpers/CodexBarCLI")
    try FileManager.default.removeItem(at: movedHelper)
    try FileManager.default.createSymbolicLink(atPath: movedHelper.path, withDestinationPath: "/usr/bin/true")
    expect(HelperReader.bundledHelper(in: moved) == nil)
    expect(HelperReader.bundledHelper(in: folder) == nil)
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
        try weeklyUsesItsActualWindowNotPrimaryPosition()
        try primaryCanBeWeeklyAndMissingIsNotOneHundred()
        try modelWeeklyIsNotTheOverallWeeklyQuota()
        try sourceIdentityIsPreservedAndCannotCrossProviders()
        try claudeDirectHTTPIncludesItsModelWindows()
        try syntheticAndUnknownWindowsCannotInventQuotas()
        try staleFailedAndResetSnapshotsNeverLookFreshInTheBar()
        rejectsUnexpectedOrAmbiguousSources()
        automaticQuarterHourAndPanelAlwaysForcesFreshRead()
        refreshModesPreserveExplicitActionsAndReconfigureTimers()
        sleepAndWakeDoNotCatchUpMissedRefreshes()
        shortSleepResumesOnlyAnInterruptedRefresh()
        try await subprocessHasBoundedOutputAndTime()
        await cancellationStopsAWholeFetch()
        try await cancellationReapsRunningHelperAndItsChild()
        try readerMustStayInsideTheApp()
    } catch { Checks.failures.append("Unexpected error: \(error)") }
    for failure in Checks.failures { print("FAIL: \(failure)") }
    print("\(Checks.assertions) assertions, \(Checks.failures.count) failures")
    exit(Checks.failures.isEmpty ? 0 : 1)
}
}
