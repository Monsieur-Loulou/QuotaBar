import AppKit
import QuotaCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel(demo: CommandLine.arguments.contains("--demo"))
    private var statusItem: NSStatusItem!
    private let statusPanel = StatusPanel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        model.onChange = { [weak self] in self?.updateStatus() }
        updateStatus()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        model.start()
        if CommandLine.arguments.contains("--preview") { showPreview() }
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if statusPanel.isVisible { statusPanel.close() } else {
            guard let buttonWindow = button.window,
                  let screen = buttonWindow.screen ?? NSScreen.main else { return }
            let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            model.settingsVisible = model.menuValues().isEmpty
            model.panelOpened()
            updateStatus()
            statusPanel.show(model: model, anchor: anchor, visibleFrame: screen.visibleFrame, button: button)
        }
    }

    private func updateStatus() {
        let values = model.menuValues()
        statusItem.button?.image = MenuBarIcon.render(values: values)
        let labels = Provider.allCases.compactMap { provider in values[provider].map { "\(provider.title) \($0)" } }
        statusItem.button?.setAccessibilityLabel(labels.isEmpty ? "QuotaBar : aucun quota disponible" :
            "Quota \(model.displayMode.qualifier) : " + labels.joined(separator: ", "))
        statusItem.button?.toolTip = "Quota hebdomadaire \(model.displayMode.qualifier) · \(model.refreshMode.title)"
    }

    private func showPreview() {
        let controller = NSHostingController(rootView: Panel(model: model))
        let window = NSWindow(contentViewController: controller)
        window.title = model.demo ? "QuotaBar · Démonstration" : "QuotaBar"
        window.styleMask = [.titled, .closable]
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func willSleep() { statusPanel.close(); model.sleep() }
    @objc private func didWake() { model.wake() }
    func applicationWillTerminate(_ notification: Notification) { statusPanel.close(); model.sleep() }
}

if CommandLine.arguments.contains("--verify-panel") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let passed = await StatusPanel.verify()
        print(passed ? "Panel content sizing, model observation and monitor lifecycle: OK" : "Panel verification: FAILED")
        exit(passed ? 0 : 1)
    }
    RunLoop.main.run()
}

if let index = CommandLine.arguments.firstIndex(of: "--render-demo"), index + 1 < CommandLine.arguments.count {
    let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let scenario = CommandLine.arguments.contains("--forecast") ? "forecast" : CommandLine.arguments.contains("--long") ? "long" : CommandLine.arguments.contains("--error") ? "error" : CommandLine.arguments.contains("--trend") ? "trend" : CommandLine.arguments.contains("--disconnected") ? "disconnected" : "normal"
    let model = AppModel(demo: true, demoScenario: scenario)
    if CommandLine.arguments.contains("--settings") { model.settingsVisible = true }
    if CommandLine.arguments.contains("--used") { model.displayMode = .used }
    if let modeIndex = CommandLine.arguments.firstIndex(of: "--cadence"), modeIndex + 1 < CommandLine.arguments.count,
       let mode = RefreshMode(rawValue: CommandLine.arguments[modeIndex + 1]) { model.refreshMode = mode }
    let light = CommandLine.arguments.contains("--light")
    let view = NSHostingView(rootView: Panel(model: model)
        .environment(\.colorScheme, light ? .light : .dark))
    view.frame = NSRect(origin: .zero, size: Panel.naturalSize(model: model))
    view.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        print("Native render failed"); exit(1)
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        print("Native render failed"); exit(1)
    }
    do { try png.write(to: destination); print("Native demo rendered: \(Int(view.frame.width)) × \(Int(view.frame.height))"); exit(0) }
    catch { print("Native render could not be saved"); exit(1) }
}

if CommandLine.arguments.contains("--verify-resources") {
    let contained = resourcesURL.path.hasPrefix(Bundle.main.bundleURL.path + "/Contents/Resources/")
    let config = try? Data(contentsOf: resourcesURL.appendingPathComponent("reader-config.json"))
    let parsed = config.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let logos = Provider.allCases.allSatisfy { !Brand.image($0).representations.isEmpty }
    let reader = HelperReader.bundledHelper()
    let readerResources = reader.map { URL(fileURLWithPath: $0).deletingLastPathComponent()
        .appendingPathComponent("CodexBar_CodexBarCore.bundle").path }
    let valid = contained && parsed?["version"] as? Int == 1 && logos
        && readerResources.map { FileManager.default.fileExists(atPath: $0) } == true
    print(valid ? "Bundled reader, configuration and both logos: OK" : "Bundled resources: FAILED")
    exit(valid ? 0 : 1)
}

if CommandLine.arguments.contains("--enable-login") {
    let model = AppModel(demo: false)
    model.setLogin(true)
    print(model.loginEnabled ? "Ouverture à la connexion : activée" :
        (model.settingsError ?? "Ouverture à la connexion : non activée"))
    exit(model.loginEnabled ? 0 : 1)
}

if CommandLine.arguments.contains("--login-status") {
    let model = AppModel(demo: false)
    print(model.loginEnabled ? "Ouverture à la connexion : activée" : "Ouverture à la connexion : désactivée")
    exit(model.loginEnabled ? 0 : 1)
}

if CommandLine.arguments.contains("--check") {
    Task {
        guard let path = HelperReader.bundledHelper() else { print("Lecteur intégré absent"); exit(1) }
        let reader = HelperReader(path: path, configPath: resourcesURL.appendingPathComponent("reader-config.json").path)
        var failed = false
        for provider in Provider.allCases {
            let started = Date()
            do {
                let snapshot = try await reader.fetch(provider)
                print("\(provider.title): \(snapshot.menuValue(now: Date(), failed: false)), \(snapshot.rows.count) limites, \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            } catch {
                print("\(provider.title): \((error as? QuotaError ?? .helperFailed).message)")
                failed = true
            }
        }
        exit(failed ? 1 : 0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
