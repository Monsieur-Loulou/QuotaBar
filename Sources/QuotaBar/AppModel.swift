import AppKit
import Combine
import QuotaCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshots: [Provider: QuotaSnapshot] = [:]
    @Published private(set) var errors: [Provider: QuotaError] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var displayDate = Date()
    @Published var settingsVisible = false
    @Published private(set) var setupVisible = false
    @Published private(set) var setupCheckStarted = false
    @Published private(set) var setupCheckedProviders = Set<Provider>()
    var needsInitialSetup: Bool { !demo && !UserDefaults.standard.bool(forKey: "quotaSetupCompleted") }
    var onSetupFinished: (() -> Void)?
    @Published var displayMode: QuotaDisplayMode = .remaining {
        didSet {
            if !demo { UserDefaults.standard.set(displayMode.rawValue, forKey: "quotaDisplayMode") }
            onChange?()
        }
    }
    @Published var refreshMode: RefreshMode = .fifteenMinutes {
        didSet {
            guard refreshMode != oldValue else { return }
            if !demo { UserDefaults.standard.set(refreshMode.rawValue, forKey: "quotaRefreshMode") }
            policy.setMode(refreshMode, now: Date())
            displayDate = Date()
            schedule()
            onChange?()
        }
    }
    @Published private(set) var enabledProviders = Set(Provider.allCases)
    var selectedProviders: [Provider] { Provider.allCases.filter { enabledProviders.contains($0) } }

    func setEnabled(_ enabled: Bool, for provider: Provider) {
        if enabled { enabledProviders.insert(provider) } else { enabledProviders.remove(provider) }
        if !demo {
            UserDefaults.standard.set(Provider.allCases.filter { !enabledProviders.contains($0) }.map(\.rawValue), forKey: "quotaDisabledProviders")
        }
        onChange?()
        if enabled {
            if refreshing { refreshAfterCurrent = true } else { refresh(force: true) }
        } else {
            schedule()
        }
    }

    func menuValues(now: Date = Date()) -> [Provider: String] {
        Dictionary(uniqueKeysWithValues: selectedProviders.compactMap { provider in
            guard let snapshot = snapshots[provider] else { return nil }
            let value = snapshot.menuValue(now: now, failed: errors[provider] != nil,
                                           mode: displayMode, freshnessInterval: freshnessInterval)
            return value == "--" ? nil : (provider, value)
        })
    }

    var freshnessInterval: TimeInterval { refreshMode.freshnessInterval }
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var settingsError: String?
    let helperPath: String
    let demo: Bool
    var onChange: (() -> Void)?
    private var policy = RefreshPolicy()
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private var refreshAfterCurrent = false
    private var trendHistory = QuotaTrendHistory()
    private let trendURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QuotaBar/trend-history.json")
    @Published private(set) var trendStorageError: String?

    init(demo: Bool, demoScenario: String = "normal") {
        self.demo = demo
        helperPath = HelperReader.bundledHelper() ?? ""
        if demo { loadDemo(scenario: demoScenario) } else {
            displayMode = QuotaDisplayMode(rawValue: UserDefaults.standard.string(forKey: "quotaDisplayMode") ?? "") ?? .remaining
            refreshMode = RefreshMode(rawValue: UserDefaults.standard.string(forKey: "quotaRefreshMode") ?? "") ?? .fifteenMinutes
            policy.setMode(refreshMode, now: Date())
            let disabled = Set(UserDefaults.standard.stringArray(forKey: "quotaDisabledProviders") ?? [])
            enabledProviders = Set(Provider.allCases.filter { !disabled.contains($0.rawValue) })
            setupVisible = needsInitialSetup
            policy.setReadAuthorization(!setupVisible)
            loadTrendHistory()
        }
    }

    func start() { if !demo { refresh(force: true) } }

    func showSetup() {
        sleep()
        policy.wake()
        policy.setReadAuthorization(false)
        setupCheckStarted = false
        setupCheckedProviders.removeAll()
        setupVisible = true
        settingsVisible = false
        onChange?()
    }

    func checkSetup() {
        guard !refreshing else { return }
        setupCheckedProviders.removeAll()
        setupCheckStarted = true
        policy.setReadAuthorization(true)
        refresh(force: true, allowPrompt: true)
        onChange?()
    }

    func finishSetup(later: Bool = false) {
        if later {
            sleep()
            policy.wake()
            policy.setReadAuthorization(false)
        } else {
            // Completing setup always follows an explicit check, even if no quota was available.
            guard setupCheckStarted, !refreshing else { return }
            if !demo { UserDefaults.standard.set(true, forKey: "quotaSetupCompleted") }
        }
        setupVisible = false
        schedule()
        onSetupFinished?()
        onChange?()
    }

    func openSetupHelp(_ provider: Provider) {
        let address = provider == .codex ? "https://developers.openai.com/codex/auth/" : "https://claude.ai/"
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    func panelOpened() {
        displayDate = Date()
        refreshLoginStatus()
        if !demo, !setupVisible, !needsInitialSetup {
            policy.setReadAuthorization(true)
            refresh(force: true)
        }
        onChange?()
    }

    /// `allowPrompt` comes only from the explicit connection check, never from the timer or panel opening.
    func refresh(force: Bool, allowPrompt: Bool = false) {
        guard !setupVisible || (setupCheckStarted && force),
              !selectedProviders.isEmpty, !demo, policy.begin(now: Date(), force: force) else { return }
        timer?.invalidate(); timer = nil
        refreshing = true
        displayDate = Date()
        generation += 1
        let currentGeneration = generation
        let reader = HelperReader(path: helperPath, configPath: resourcesURL.appendingPathComponent("reader-config.json").path)
        refreshTask = Task { [weak self] in
            await withTaskGroup(of: (Provider, Result<QuotaSnapshot, QuotaError>).self) { group in
                for provider in self?.selectedProviders ?? [] {
                    group.addTask {
                        do { return (provider, .success(try await reader.fetch(provider, allowPrompt: allowPrompt))) }
                        catch { return (provider, .failure(error as? QuotaError ?? .helperFailed)) }
                    }
                }
                for await (provider, result) in group {
                    guard let self, !Task.isCancelled, self.generation == currentGeneration else { continue }
                    switch result {
                    case let .success(snapshot):
                        self.trendHistory.record(snapshot)
                        self.snapshots[provider] = snapshot
                        self.errors[provider] = nil
                    case let .failure(error):
                        self.trendHistory.interrupt(provider)
                        self.errors[provider] = error
                    }
                    if self.setupVisible { self.setupCheckedProviders.insert(provider) }
                    self.displayDate = Date()
                    self.onChange?()
                }
            }
            guard let self, !Task.isCancelled, self.generation == currentGeneration else { return }
            self.saveTrendHistory()
            self.policy.finish()
            self.refreshing = false
            self.refreshTask = nil
            self.displayDate = Date()
            self.schedule()
            self.onChange?()
            if self.refreshAfterCurrent {
                self.refreshAfterCurrent = false
                self.refresh(force: true)
            }
        }
        onChange?()
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard !demo, !setupVisible, policy.readsAuthorized, !selectedProviders.isEmpty, !policy.asleep, !refreshing else { return }
        let now = Date()
        // A local expiry event clears old menu values, including in on-open mode. It does not force a read.
        let expirations = snapshots.compactMap { provider, snapshot -> Date? in
            guard enabledProviders.contains(provider), errors[provider] == nil else { return nil }
            return snapshot.displayExpiry(freshnessInterval: freshnessInterval)
        }.filter { $0 > now }
        guard let next = (expirations + [policy.nextAutomatic].compactMap { $0 }).min() else { return }
        let timer = Timer(timeInterval: max(1, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.displayDate = Date()
                self.onChange?()
                self.refresh(force: false)
                if !self.refreshing { self.schedule() }
            }
        }
        timer.tolerance = 2
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func sleep() {
        generation += 1
        timer?.invalidate(); timer = nil
        refreshTask?.cancel(); refreshTask = nil
        policy.sleep(); refreshing = false
        refreshAfterCurrent = false
        for provider in Provider.allCases { trendHistory.interrupt(provider) }
        if !demo { saveTrendHistory() }
    }

    func wake() {
        policy.wake()
        displayDate = Date()
        if !demo { refresh(force: false); if !refreshing { schedule() } }
        onChange?()
    }

    func refreshLoginStatus() {
        guard !demo else { return }
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        settingsError = status == .requiresApproval
            ? "Autorise QuotaBar dans Réglages Système → Général → Ouverture." : nil
    }

    func setLogin(_ enabled: Bool) {
        guard !demo else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            settingsError = "Impossible de changer le lancement au démarrage. Installe d’abord QuotaBar dans Applications."
        }
    }

    func openAccountSettings(_ provider: Provider) {
        let address = provider == .codex ? "https://chatgpt.com/codex/cloud/settings/analytics#usage" : "https://claude.ai/settings/usage"
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    func trend(for provider: Provider, rowID: String) -> QuotaTrend? {
        guard errors[provider] == nil, let snapshot = snapshots[provider],
              snapshot.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              displayDate.timeIntervalSince(snapshot.measuredAt) <= freshnessInterval else { return nil }
        return trendHistory.trend(for: provider, rowID: rowID, now: displayDate)
    }

    private func loadTrendHistory() {
        guard FileManager.default.fileExists(atPath: trendURL.path) else { return }
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: trendURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            trendHistory = try JSONDecoder().decode(QuotaTrendHistory.self, from: Data(contentsOf: trendURL))
            trendHistory.prune(now: Date())
            // An app restart is an observation gap, even if the last sample was recent.
            for provider in Provider.allCases { trendHistory.interrupt(provider) }
        } catch { trendStorageError = "Historique illisible : la moyenne repart de nouvelles mesures." }
    }

    private func saveTrendHistory() {
        trendHistory.prune(now: Date())
        do {
            try FileManager.default.createDirectory(at: trendURL.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(trendHistory).write(to: trendURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: trendURL.path)
            trendStorageError = nil
        } catch { trendStorageError = "Historique non enregistré : la moyenne reste disponible pendant cette session." }
    }

    private func loadDemo(scenario: String) {
        if scenario.hasPrefix("setup") {
            setupVisible = true
            setupCheckStarted = scenario != "setup"
            if setupCheckStarted { setupCheckedProviders = Set(Provider.allCases) }
            if scenario == "setup" { return }
        }
        if scenario == "loading" { return }
        if scenario == "error" || scenario == "setup-error" {
            errors[.codex] = .unavailable
            errors[.claude] = .timeout
            return
        }
        let now = Date()
        snapshots[.codex] = QuotaSnapshot(provider: .codex, rows: [
            QuotaRow(id: "weekly", title: "Hebdomadaire", remaining: 98,
                     resetsAt: now.addingTimeInterval(5 * 86400 + 7 * 3600), isWeekly: true),
        ], measuredAt: now, accountLabel: "demo@openai.example")
        snapshots[.claude] = QuotaSnapshot(provider: .claude, rows: [
            QuotaRow(id: "session", title: "Session · 5 heures", remaining: 99, resetsAt: now.addingTimeInterval(4 * 3600)),
            QuotaRow(id: "weekly", title: "Hebdomadaire", remaining: 100, resetsAt: now.addingTimeInterval(6 * 86400 + 20 * 3600), isWeekly: true),
            QuotaRow(id: "fable", title: "Fable only", remaining: 100, resetsAt: now.addingTimeInterval(6 * 86400 + 20 * 3600)),
        ], measuredAt: now, accountLabel: "demo@claude.example")
        if scenario == "disconnected" { errors[.codex] = .unavailable }
        if scenario == "forecast" {
            snapshots[.codex] = QuotaSnapshot(provider: .codex, rows: [
                QuotaRow(id: "weekly", title: "Hebdomadaire", remaining: 70, resetsAt: now.addingTimeInterval(24 * 3600), isWeekly: true),
            ], measuredAt: now, accountLabel: "demo@openai.example")
            snapshots[.claude] = QuotaSnapshot(provider: .claude, rows: [
                QuotaRow(id: "weekly", title: "Hebdomadaire", remaining: 50, resetsAt: now.addingTimeInterval(24 * 3600), isWeekly: true),
                QuotaRow(id: "session", title: "Session · 5 heures", remaining: 10, resetsAt: now.addingTimeInterval(4 * 3600)),
                QuotaRow(id: "fable", title: "Fable only", remaining: 100, resetsAt: now.addingTimeInterval(24 * 3600)),
            ], measuredAt: now, accountLabel: "demo@claude.example")
            for provider in Provider.allCases {
                guard let snapshot = snapshots[provider] else { continue }
                for index in 0...4 {
                    let rows = snapshot.rows.map { row in
                        let rate: Double = row.id == "session" ? 3 : row.id == "fable" ? 0 : 1.8
                        return QuotaRow(id: row.id, title: row.title,
                                        remaining: row.remaining.map { $0 + Double(4 - index) * rate / 4 },
                                        resetsAt: row.resetsAt, isWeekly: row.isWeekly)
                    }
                    trendHistory.record(QuotaSnapshot(provider: provider, rows: rows,
                        measuredAt: now.addingTimeInterval(Double(index - 4) * 900), accountLabel: snapshot.accountLabel))
                }
            }
        }
        if scenario == "trend" {
            // Synthetic observations exercise the consumption line and spike without reading accounts.
            for provider in Provider.allCases {
                guard let snapshot = snapshots[provider] else { continue }
                for index in 0...4 {
                    let rows = snapshot.rows.map { row in
                        QuotaRow(id: row.id, title: row.title,
                                 remaining: row.remaining.map { min(100, $0 + (index == 4 ? 0 : 3 + Double(3 - index) * 0.5)) },
                                 resetsAt: row.resetsAt, isWeekly: row.isWeekly)
                    }
                    trendHistory.record(QuotaSnapshot(provider: provider, rows: rows,
                        measuredAt: now.addingTimeInterval(Double(index - 4) * 900), accountLabel: snapshot.accountLabel))
                }
            }
        }
        if scenario == "long" {
            let rows = (0..<12).map { index in
                QuotaRow(id: "extra-\(index)", title: "Limite supplémentaire avec un intitulé particulièrement long \(index + 1)",
                         remaining: Double(100 - index * 7), resetsAt: now.addingTimeInterval(86400 * 4))
            }
            snapshots[.claude] = QuotaSnapshot(provider: .claude, rows: snapshots[.claude]!.rows + rows,
                measuredAt: now, accountLabel: "adresse.de.compte.particulierement.longue@claude.example")
        }
    }
}

let resourcesURL: URL = {
    if Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL {
        return resources.appendingPathComponent("QuotaBar_QuotaBar.bundle/Resources")
    }
    return Bundle.module.resourceURL!.appendingPathComponent("Resources")
}()
