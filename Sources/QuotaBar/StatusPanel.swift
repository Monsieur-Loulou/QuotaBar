import AppKit
import Combine
import QuotaCore
import SwiftUI

/// All coordinates are AppKit screen coordinates, independent of a button's flipped view.
enum StatusPanelGeometry {
    static let preferredWidth: CGFloat = 350

    static func maximumHeight(anchor: NSRect, visibleFrame: NSRect) -> CGFloat {
        let area = visibleFrame.insetBy(dx: 8, dy: 8)
        return max(1, min(anchor.minY - 6, area.maxY) - area.minY)
    }

    static func frame(anchor: NSRect, visibleFrame: NSRect, contentHeight: CGFloat) -> NSRect {
        let area = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(preferredWidth, area.width)
        let height = min(contentHeight, maximumHeight(anchor: anchor, visibleFrame: visibleFrame))
        let x = min(max(anchor.midX - width / 2, area.minX), area.maxX - width)
        let top = min(anchor.minY - 6, area.maxY)
        return NSRect(x: x, y: top - height, width: width, height: height)
    }
}

enum PanelInput {
    case inside, statusButton, outside, escape, otherKey
    var dismisses: Bool { self == .outside || self == .escape }
}

private final class QuotaWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusPanel: NSObject, NSWindowDelegate {
    private let window: NSPanel
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var content: NSHostingController<Panel>?
    private var model: AppModel?
    private var modelObservation: AnyCancellable?
    private var resizeRevision = 0
    private var anchor = NSRect.zero
    private var visibleFrame = NSRect.zero
    private weak var statusButton: NSStatusBarButton?
    var isVisible: Bool { window.isVisible }

    override init() {
        window = QuotaWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        window.level = .popUpMenu
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.animationBehavior = .none
        NotificationCenter.default.addObserver(self, selector: #selector(close), name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(close), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(close), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    func show(model: AppModel, anchor: NSRect, visibleFrame: NSRect, button: NSStatusBarButton) {
        statusButton = button
        configure(model: model, anchor: anchor, visibleFrame: visibleFrame)
        installMonitors()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func configure(model: AppModel, anchor: NSRect, visibleFrame: NSRect) {
        self.model = model
        self.anchor = anchor
        self.visibleFrame = visibleFrame
        let content = NSHostingController(rootView: Panel(model: model))
        content.sizingOptions = []
        self.content = content
        window.contentViewController = content
        resizeToFit()
        modelObservation = model.objectWillChange.sink { [weak self, weak model] _ in
            // Published values and SwiftUI must be updated before measuring the new content.
            Task { @MainActor [weak self, weak model] in
                guard let self, let model, self.model === model else { return }
                self.resizeToFit()
            }
        }
    }

    private func resizeToFit() {
        guard let model, let content else { return }
        let width = min(StatusPanelGeometry.preferredWidth, visibleFrame.width - 16)
        let natural = Panel.naturalSize(model: model, width: width)
        let frame = StatusPanelGeometry.frame(anchor: anchor, visibleFrame: visibleFrame, contentHeight: natural.height)
        content.rootView = Panel(model: model, width: width,
                                 constrainedHeight: natural.height > frame.height ? frame.height : nil)
        window.setFrame(frame, display: window.isVisible)
        content.view.layoutSubtreeIfNeeded()
        resizeRevision += 1
    }

    @objc func close() {
        removeMonitors()
        window.orderOut(nil)
        statusButton = nil
        modelObservation = nil
        model = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // The button action owns toggling; closing before it runs would reopen the panel.
        if let event = NSApp.currentEvent, event.window === statusButton?.window,
           [.leftMouseDown, .leftMouseUp].contains(event.type) { return }
        close()
    }

    @discardableResult private func handle(_ input: PanelInput) -> Bool {
        if input.dismisses { close() }
        return input != .escape
    }

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let forwardsEvent = MainActor.assumeIsolated {
                guard let self else { return true }
                let input: PanelInput
                if event.type == .keyDown {
                    input = event.keyCode == 53 ? .escape : .otherKey
                } else if event.window === self.statusButton?.window {
                    input = .statusButton
                } else {
                    input = event.window === self.window ? .inside : .outside
                }
                return self.handle(input)
            }
            return forwardsEvent ? event : nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.handle(.outside) }
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    /// Exercises production layout and lifecycle without displaying or controlling the desktop.
    static func verify() async -> Bool {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 875),
                       NSRect(x: -1920, y: 0, width: 1920, height: 1055),
                       NSRect(x: 0, y: 900, width: 1024, height: 700),
                       NSRect(x: 0, y: 0, width: 800, height: 380),
                       NSRect(x: 0, y: 0, width: 360, height: 600)]
        for screen in screens {
            for x in [screen.minX, screen.midX, screen.maxX] {
                for height: CGFloat in [180, 460, 1200] {
                    let anchor = NSRect(x: x - 24, y: screen.maxY, width: 48, height: 24)
                    let frame = StatusPanelGeometry.frame(anchor: anchor, visibleFrame: screen, contentHeight: height)
                    guard screen.contains(frame), frame.maxY < anchor.minY,
                          frame.width <= 350, frame.height <= height else { return false }
                }
            }
        }
        let panel = StatusPanel()
        // Measure real SwiftUI content, including settings, long data, loading and errors.
        for screen in screens {
            for scenario in ["normal", "trend", "forecast", "long", "loading", "error", "disconnected", "setup", "setup-ready", "setup-error"] {
                let model = AppModel(demo: true, demoScenario: scenario)
                let anchor = NSRect(x: screen.midX, y: screen.maxY, width: 48, height: 24)
                panel.configure(model: model, anchor: anchor, visibleFrame: screen)
                for settingsVisible in [false, true, false] {
                    model.settingsVisible = settingsVisible
                    panel.resizeToFit()
                    let natural = Panel.naturalSize(model: model, width: panel.window.frame.width)
                    let expected = StatusPanelGeometry.frame(anchor: anchor, visibleFrame: screen, contentHeight: natural.height)
                    guard panel.window.frame == expected, panel.content?.view.frame.size == expected.size else { return false }
                    let shouldScroll = natural.height > expected.height
                    guard (panel.content?.rootView.constrainedHeight != nil) == shouldScroll else { return false }
                }
            }
        }
        let model = AppModel(demo: true)
        let natural = Panel.naturalSize(model: model)
        model.settingsVisible = true
        let settingsSize = Panel.naturalSize(model: model)
        guard natural.height > 200, natural.height < 550,
              settingsSize.height != natural.height, settingsSize.height < 700 else { return false }
        for input in [PanelInput.inside, .statusButton, .otherKey] {
            panel.installMonitors()
            guard panel.handle(input), panel.localMonitor != nil else { return false }
            panel.close()
        }
        for input in [PanelInput.outside, .escape, .outside] {
            panel.installMonitors()
            guard panel.localMonitor != nil, panel.globalMonitor != nil else { return false }
            let forwardsEvent = panel.handle(input)
            guard forwardsEvent == (input != .escape) else { return false }
            guard panel.localMonitor == nil, panel.globalMonitor == nil, !panel.isVisible else { return false }
        }
        // Exercise the same observation path used by a displayed panel, without showing a window.
        let screen = screens[0]
        let eventModel = AppModel(demo: true)
        panel.configure(model: eventModel, anchor: NSRect(x: screen.midX, y: screen.maxY, width: 48, height: 24), visibleFrame: screen)
        let quotaFrame = panel.window.frame
        for settingsVisible in [true, false] {
            let before = panel.resizeRevision
            eventModel.settingsVisible = settingsVisible
            let deadline = Date().addingTimeInterval(2)
            while panel.resizeRevision == before, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard panel.resizeRevision > before else { return false }
            if settingsVisible {
                guard panel.window.frame.height != quotaFrame.height else { return false }
            } else {
                guard panel.window.frame == quotaFrame else { return false }
            }
        }
        panel.close()
        guard panel.modelObservation == nil else { return false }
        let selection = AppModel(demo: true)
        guard selection.menuValues().count == 2 else { return false }
        selection.setEnabled(false, for: .codex)
        guard selection.menuValues().keys.sorted(by: { $0.rawValue < $1.rawValue }) == [.claude] else { return false }
        selection.setEnabled(false, for: .claude)
        guard selection.menuValues().isEmpty, !MenuBarIcon.render(values: selection.menuValues()).representations.isEmpty else { return false }
        selection.setEnabled(true, for: .claude)
        guard selection.menuValues().count == 1 else { return false }
        let disconnected = AppModel(demo: true, demoScenario: "disconnected")
        guard disconnected.menuValues()[.codex] == nil, disconnected.menuValues()[.claude] != nil else { return false }
        selection.refreshMode = .thirtyMinutes
        guard selection.menuValues(now: selection.displayDate.addingTimeInterval(1200))[.claude] != nil else { return false }
        selection.refreshMode = .onOpen
        guard selection.menuValues(now: selection.displayDate.addingTimeInterval(1200)).isEmpty else { return false }
        for mode in RefreshMode.allCases {
            selection.settingsVisible = true
            selection.refreshMode = mode
            let height = Panel.naturalSize(model: selection).height
            guard height > 200, height < 700 else { return false }
        }
        return true
    }
}
