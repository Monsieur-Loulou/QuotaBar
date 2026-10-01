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
    case helperMissing, helperFailed, timeout, cancelled, oversizedOutput, invalidResponse
    case unavailable, multipleAccounts, unsupportedSource

    public var message: String {
        switch self {
        case .helperMissing: "Le lecteur intégré est absent. Reconstruis ou réinstalle QuotaBar."
        case .timeout: "La lecture a pris trop de temps. Réessaie au prochain refresh."
        case .cancelled: "Lecture interrompue."
        case .multipleAccounts: "Plusieurs comptes sont renvoyés. Impossible de choisir un quota sans ambiguïté."
        case .unsupportedSource: "Cette source ne convient pas au mode léger."
        case .unavailable, .helperFailed: "Quotas indisponibles. Vérifie ta connexion dans Codex ou sur claude.ai, puis actualise."
        case .invalidResponse, .oversizedOutput: "La réponse du lecteur de quotas est invalide."
        }
    }
}

/// Decodes quota fields and the display email. Raw errors, credits and cached web extras are discarded.
public enum QuotaDecoder {
    public static func decode(_ data: Data, for provider: Provider, now: Date = Date()) throws -> QuotaSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw QuotaError.invalidResponse }
            return date
        }
        let all: [Payload]
        do { all = try decoder.decode([Payload].self, from: data) }
        catch { throw QuotaError.invalidResponse }
        let matching = all.filter { $0.provider == provider.rawValue }
        guard matching.count <= 1 else { throw QuotaError.multipleAccounts }
        guard let payload = matching.first, payload.error == nil, let usage = payload.usage else {
            throw QuotaError.unavailable
        }
        // Claude's web strategy is direct HTTP. Codex's web strategy runs a WebView and is forbidden here.
        guard payload.source == (provider == .claude ? "web" : "oauth") else { throw QuotaError.unsupportedSource }
        guard usage.identity?.providerID.map({ $0 == provider.rawValue }) ?? true else {
            throw QuotaError.invalidResponse
        }
        guard [nil, "exact", "percentOnly"].contains(usage.dataConfidence),
              now.timeIntervalSince(usage.updatedAt) <= 16 * 60,
              usage.updatedAt.timeIntervalSince(now) < 60 else { throw QuotaError.unavailable }
        var rows: [QuotaRow] = []
        for (id, window, label) in [
            ("primary", usage.primary, payload.rateWindowLabels?.primary),
            ("secondary", usage.secondary, payload.rateWindowLabels?.secondary),
            ("tertiary", usage.tertiary, payload.rateWindowLabels?.tertiary),
        ] {
            guard let window, window.isSyntheticPlaceholder != true else { continue }
            let isWeekly = id != "tertiary" && (window.windowMinutes == 10080 ||
                (window.windowMinutes == nil && id == "secondary"))
            let title = isWeekly ? "Hebdomadaire" :
                (window.windowMinutes == 300 ? "Session · 5 heures" : (label ?? "Limite supplémentaire"))
            rows.append(try window.row(id: id, title: title, isWeekly: isWeekly))
        }
        for extra in usage.extraRateWindows ?? [] {
            guard extra.window.isSyntheticPlaceholder != true else { continue }
            rows.append(try extra.window.row(id: "extra-" + extra.id, title: extra.title,
                                             isWeekly: false, usageKnown: extra.usageKnown != false))
        }
        guard !rows.isEmpty, rows.count <= 30, Set(rows.map(\.id)).count == rows.count else {
            throw QuotaError.unavailable
        }
        let label = (usage.identity?.accountEmail ?? usage.accountEmail)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return QuotaSnapshot(provider: provider, rows: rows, measuredAt: usage.updatedAt,
                             accountLabel: label.flatMap { $0.isEmpty ? nil : String($0.prefix(100)) })
    }
}

private struct Payload: Decodable {
    let provider: String
    let source: String?
    let usage: Usage?
    let rateWindowLabels: Labels?
    let error: Failure?
    struct Failure: Decodable { let code: Int? }
}
private struct Labels: Decodable { let primary: String?; let secondary: String?; let tertiary: String? }
private struct Usage: Decodable {
    let primary: Window?; let secondary: Window?; let tertiary: Window?
    let extraRateWindows: [Extra]?
    let updatedAt: Date
    let dataConfidence: String?
    let identity: Identity?
    let accountEmail: String?
}
private struct Identity: Decodable { let providerID: String?; let accountEmail: String? }
private struct Extra: Decodable { let id: String; let title: String; let window: Window; let usageKnown: Bool? }
private struct Window: Decodable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Date?
    let resetDescription: String?
    let isSyntheticPlaceholder: Bool?

    func row(id: String, title: String, isWeekly: Bool, usageKnown: Bool = true) throws -> QuotaRow {
        if let usedPercent, (!usedPercent.isFinite || usedPercent < 0) { throw QuotaError.invalidResponse }
        let remaining = usageKnown ? usedPercent.map { max(0, 100 - $0) } : nil
        return QuotaRow(id: id, title: String(title.prefix(80)), remaining: remaining,
                        resetsAt: resetsAt, resetDescription: resetDescription.map { String($0.prefix(120)) },
                        isWeekly: isWeekly)
    }
}
