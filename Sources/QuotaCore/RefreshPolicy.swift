import Foundation

public enum RefreshMode: String, CaseIterable, Sendable {
    case onOpen, oneMinute, fiveMinutes, fifteenMinutes, thirtyMinutes

    public var title: String {
        switch self {
        case .onOpen: "À l’ouverture"
        case .oneMinute: "Toutes les minutes"
        case .fiveMinutes: "Toutes les 5 min"
        case .fifteenMinutes: "Toutes les 15 min"
        case .thirtyMinutes: "Toutes les 30 min"
        }
    }
    public var interval: TimeInterval? {
        switch self {
        case .onOpen: nil
        case .oneMinute: 60
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .thirtyMinutes: 1800
        }
    }
    public var freshnessInterval: TimeInterval { max(16 * 60, (interval ?? 0) + 60) }
    public var description: String {
        switch self {
        case .onOpen: "Au lancement et à chaque ouverture du panneau."
        default: "À cette fréquence et à l’ouverture du panneau. En pause pendant la veille."
        }
    }
}

/// Concurrent requests share one in-flight read. On-open mode has no automatic timer.
public struct RefreshPolicy: Sendable {
    public private(set) var mode: RefreshMode
    public private(set) var nextAutomatic: Date?
    public private(set) var running = false
    public private(set) var asleep = false
    public private(set) var readsAuthorized = true
    public init(mode: RefreshMode = .fifteenMinutes) { self.mode = mode }

    public mutating func setMode(_ mode: RefreshMode, now: Date) {
        self.mode = mode
        nextAutomatic = readsAuthorized ? mode.interval.map { now.addingTimeInterval($0) } : nil
    }

    public mutating func setReadAuthorization(_ authorized: Bool) {
        readsAuthorized = authorized
        if !authorized { nextAutomatic = nil }
    }

    public mutating func begin(now: Date, force: Bool) -> Bool {
        let automaticDue = mode.interval != nil && (nextAutomatic.map { now >= $0 } ?? true)
        guard readsAuthorized, !asleep, !running, force || automaticDue else { return false }
        running = true
        nextAutomatic = mode.interval.map { now.addingTimeInterval($0) }
        return true
    }
    public mutating func finish() { running = false }
    public mutating func sleep() {
        // Only automatic modes resume an interrupted read without an explicit action.
        if running, mode.interval != nil { nextAutomatic = nil }
        asleep = true
        running = false
    }
    public mutating func wake() { asleep = false }
}
