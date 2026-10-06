import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case codex, claude
    public var title: String { self == .codex ? "OpenAI" : "Claude" }
}

public enum QuotaDisplayMode: String, CaseIterable, Sendable {
    case remaining, used
    public var title: String { self == .remaining ? "Restant" : "Consommé" }
    public var qualifier: String { self == .remaining ? "restant" : "consommé" }
    public func percentage(_ remaining: Double?) -> Int? {
        guard let remaining, remaining.isFinite else { return nil }
        let value = min(100, max(0, remaining))
        return Int((self == .remaining ? value : 100 - value).rounded(.down))
    }
}

public enum QuotaResetLabel {
    public static func dateText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE d MMM · HH:mm"
        return formatter.string(from: date)
    }

    public static func text(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        let label = "Remise à zéro : " + dateText(date, timeZone: timeZone)
        return date <= now ? label + " · en attente de lecture" : label
    }
}

public struct QuotaRow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let remaining: Double?
    public let resetsAt: Date?
    public let resetDescription: String?
    public let isWeekly: Bool

    public init(id: String, title: String, remaining: Double?, resetsAt: Date?,
                resetDescription: String? = nil, isWeekly: Bool = false) {
        self.id = id; self.title = title; self.remaining = remaining
        self.resetsAt = resetsAt; self.resetDescription = resetDescription; self.isWeekly = isWeekly
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let provider: Provider
    public let rows: [QuotaRow]
    public let measuredAt: Date
    public let accountLabel: String?

    public init(provider: Provider, rows: [QuotaRow], measuredAt: Date, accountLabel: String? = nil) {
        self.provider = provider; self.rows = rows; self.measuredAt = measuredAt
        self.accountLabel = accountLabel
    }

    public var weekly: QuotaRow? { rows.first { $0.isWeekly } }

    public func displayExpiry(freshnessInterval: TimeInterval) -> Date {
        let ageExpiry = measuredAt.addingTimeInterval(freshnessInterval)
        return min(ageExpiry, weekly?.resetsAt ?? ageExpiry).addingTimeInterval(1)
    }

    public func menuValue(now: Date, failed: Bool, mode: QuotaDisplayMode = .remaining, freshnessInterval: TimeInterval = 16 * 60) -> String {
        guard !failed, now.timeIntervalSince(measuredAt) <= freshnessInterval,
              measuredAt.timeIntervalSince(now) < 60,
              let weekly, let remaining = weekly.remaining,
              weekly.resetsAt.map({ $0 > now }) ?? true else { return "--" }
        return "\(mode.percentage(remaining)!)%"
    }
}

public enum QuotaError: Error, Equatable, Sendable {
    case helperFailed, timeout, cancelled, oversizedOutput, invalidResponse, unavailable
    case codexMissing, codexSignedOut, claudeSignedOut, claudeExpired

    public var message: String {
        switch self {
        case .timeout: "La lecture a pris trop de temps. Réessaie au prochain refresh."
        case .cancelled: "Lecture interrompue."
        case .codexMissing: "Codex est introuvable sur ce Mac. Installe l’app ChatGPT et connecte Codex."
        case .codexSignedOut: "Connecte-toi à Codex sur ce Mac, puis actualise."
        case .claudeSignedOut: "Connecte-toi à Claude Code sur ce Mac, puis actualise."
        case .claudeExpired: "Connexion Claude Code expirée. Ouvre Claude Code pour la renouveler, puis actualise."
        case .unavailable, .helperFailed: "Quotas indisponibles pour le moment. Réessaie au prochain refresh."
        case .invalidResponse, .oversizedOutput: "La réponse reçue est invalide."
        }
    }
}

/// Turns the official Codex and Claude answers into rows. Everything else in them is discarded.
public enum QuotaDecoder {
    /// `account` and `limits` are the results of `account/read` and `account/rateLimits/read` from `codex app-server`.
    public static func codex(account: Data, limits: Data, now: Date = Date()) throws -> QuotaSnapshot {
        let account = try decode(CodexAccount.self, account)
        guard let identity = account.account else { throw QuotaError.codexSignedOut }
        let limits = try decode(CodexLimits.self, limits).rateLimits
        var rows: [QuotaRow] = []
        for (id, window) in [("primary", limits?.primary), ("secondary", limits?.secondary)] {
            guard let window else { continue }
            let minutes = window.windowDurationMins
            rows.append(try row(id: id, used: window.usedPercent, minutes: minutes,
                                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }))
        }
        return try snapshot(.codex, rows: rows, label: identity.email, now: now)
    }

    /// `usage` and `profile` are the answers of Claude's `/api/oauth/usage` and `/api/oauth/profile`.
    public static func claude(usage: Data, profile: Data?, now: Date = Date()) throws -> QuotaSnapshot {
        let usage = try decode(ClaudeUsagePayload.self, usage)
        var rows: [QuotaRow] = []
        for (id, window, minutes, title) in [
            ("five_hour", usage.five_hour, 300, nil), ("seven_day", usage.seven_day, 10080, nil),
            ("seven_day_opus", usage.seven_day_opus, nil, "Opus · hebdomadaire"),
            ("seven_day_sonnet", usage.seven_day_sonnet, nil, "Sonnet · hebdomadaire"),
        ] as [(String, ClaudeWindow?, Int?, String?)] {
            guard let window else { continue }
            rows.append(try row(id: id, used: window.utilization, minutes: minutes,
                                resetsAt: window.resets_at.flatMap(parseDate), title: title))
        }
        let email = profile.flatMap { try? JSONDecoder().decode(ClaudeProfile.self, from: $0) }?.account?.email
        return try snapshot(.claude, rows: rows, label: email, now: now)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw QuotaError.invalidResponse }
    }

    private static func row(id: String, used: Double?, minutes: Int?, resetsAt: Date?, title: String? = nil) throws -> QuotaRow {
        if let used, !used.isFinite || used < 0 { throw QuotaError.invalidResponse }
        let isWeekly = minutes == 10080
        let title = title ?? (isWeekly ? "Hebdomadaire" : minutes == 300 ? "Session · 5 heures" : "Limite supplémentaire")
        return QuotaRow(id: id, title: title, remaining: used.map { max(0, 100 - $0) },
                        resetsAt: resetsAt, isWeekly: isWeekly)
    }

    private static func snapshot(_ provider: Provider, rows: [QuotaRow], label: String?, now: Date) throws -> QuotaSnapshot {
        guard !rows.isEmpty else { throw QuotaError.unavailable }
        let label = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return QuotaSnapshot(provider: provider, rows: rows, measuredAt: now,
                             accountLabel: label.flatMap { $0.isEmpty ? nil : String($0.prefix(100)) })
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct CodexAccount: Decodable {
    let account: Identity?
    struct Identity: Decodable { let email: String? }
}
private struct CodexLimits: Decodable {
    let rateLimits: Limits?
    struct Limits: Decodable { let primary: Window?; let secondary: Window? }
    struct Window: Decodable { let usedPercent: Double?; let windowDurationMins: Int?; let resetsAt: Double? }
}
private struct ClaudeUsagePayload: Decodable {
    let five_hour: ClaudeWindow?; let seven_day: ClaudeWindow?
    let seven_day_opus: ClaudeWindow?; let seven_day_sonnet: ClaudeWindow?
}
private struct ClaudeWindow: Decodable { let utilization: Double?; let resets_at: String? }
private struct ClaudeProfile: Decodable {
    let account: Account?
    struct Account: Decodable { let email: String? }
}
