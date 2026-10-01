import AppKit
import QuotaCore
import SwiftUI

enum Brand {
    static func image(_ provider: Provider) -> NSImage {
        let url = resourcesURL.appendingPathComponent("\(provider.rawValue).svg")
        let image = NSImage(contentsOf: url) ?? NSImage(size: NSSize(width: 20, height: 20))
        image.isTemplate = true
        return image
    }
    static func color(_ provider: Provider) -> Color {
        provider == .codex ? Color(red: 0.28, green: 0.68, blue: 0.72) : Color(red: 0.82, green: 0.49, blue: 0.37)
    }
    static func ink(_ provider: Provider, dark: Bool) -> Color {
        if provider == .codex {
            return dark ? Color(red: 0.45, green: 0.79, blue: 0.81) : Color(red: 0.13, green: 0.45, blue: 0.49)
        }
        return dark ? Color(red: 0.93, green: 0.65, blue: 0.51) : Color(red: 0.65, green: 0.31, blue: 0.20)
    }
}

struct Panel: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    var width: CGFloat = 350
    // Only used when the measured content is taller than the available screen.
    var constrainedHeight: CGFloat? = nil

    var body: some View {
        Group {
            if let constrainedHeight {
                ScrollView { content }
                    .frame(height: constrainedHeight)
            } else {
                content
            }
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.settingsVisible ? "Réglages" : "QuotaBar")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if model.demo { Text("DÉMO").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange) }
                if model.refreshing {
                    Text("Actualisation…").font(.system(size: 10)).foregroundStyle(.secondary)
                } else if !model.settingsVisible {
                    Text(model.displayMode.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            if model.settingsVisible { settings } else { quotas }
            Divider()
            HStack(spacing: 16) {
                Button {
                    model.settingsVisible.toggle()
                    if model.settingsVisible { model.refreshLoginStatus() }
                } label: {
                    Label(model.settingsVisible ? "Retour" : "Réglages", systemImage: model.settingsVisible ? "chevron.left" : "gearshape")
                }
                .buttonStyle(.plain)
                Spacer()
                Button { model.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(model.refreshing || model.demo)
                    .help("Actualiser les IA suivies").accessibilityLabel("Actualiser les quotas")
                Button("Quitter") { NSApp.terminate(nil) }.buttonStyle(.plain)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var quotas: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.selectedProviders.isEmpty {
                Text("Active une IA dans les réglages.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(model.selectedProviders, id: \.self) { provider in
                let ink = Brand.ink(provider, dark: colorScheme == .dark)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Image(nsImage: Brand.image(provider)).resizable().frame(width: 19, height: 19)
                            .foregroundStyle(ink)
                        Text(provider.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                            .fixedSize()
                        Spacer(minLength: 4)
                        if let snapshot = model.snapshots[provider] {
                            Text(snapshot.accountLabel ?? "Compte non identifié")
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                .truncationMode(.middle)
                                .help(snapshot.accountLabel ?? "Compte non identifié")
                        }
                    }
                    if let error = model.errors[provider] {
                        Text(error.message).font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let snapshot = model.snapshots[provider] {
                        let stale = model.errors[provider] != nil || model.displayDate.timeIntervalSince(snapshot.measuredAt) > model.freshnessInterval
                        if stale { Text("Dernière lecture connue").font(.system(size: 10)).foregroundStyle(.secondary) }
                        VStack(spacing: 10) {
                            // The overall weekly allowance comes first in both provider sections.
                            ForEach(snapshot.rows.sorted { $0.isWeekly && !$1.isWeekly }) { row in
                                QuotaBarRow(row: row, mode: model.displayMode, ink: ink, now: model.displayDate,
                                            trend: stale ? nil : model.trend(for: provider, rowID: row.id), isFresh: !stale)
                            }
                        }.opacity(stale ? 0.5 : 1)
                    } else if model.errors[provider] == nil {
                        Text("Lecture des quotas…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.color(provider).opacity(colorScheme == .dark ? 0.12 : 0.07),
                            in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSection("AFFICHAGE") {
                HStack {
                    Text("Pourcentages")
                    Spacer()
                    Picker("Pourcentages", selection: $model.displayMode) {
                        ForEach(QuotaDisplayMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 165)
                }
                Toggle("Ouvrir à la connexion du Mac", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    .toggleStyle(.switch).controlSize(.small).disabled(model.demo)
            }
            settingsSection("ACTUALISATION") {
                HStack {
                    Text("Fréquence")
                    Spacer()
                    Picker("Fréquence d’actualisation", selection: $model.refreshMode) {
                        ForEach(RefreshMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }.labelsHidden().frame(width: 165)
                }
                Text(model.refreshMode.description).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            settingsSection("IA SUIVIES") {
                ForEach(Provider.allCases, id: \.self) { provider in
                    HStack(spacing: 8) {
                        let ink = Brand.ink(provider, dark: colorScheme == .dark)
                        Image(nsImage: Brand.image(provider)).resizable().frame(width: 20, height: 20).foregroundStyle(ink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.title).fontWeight(.semibold).foregroundStyle(ink)
                            Text(providerStatus(provider)).font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(model.errors[provider]?.message ?? model.snapshots[provider]?.accountLabel ?? "Active cette IA pour lire son quota.")
                        }
                        Spacer(minLength: 4)
                        Button { model.openAccountSettings(provider) } label: { Image(systemName: "arrow.up.right") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(provider == .codex ? "Gérer le compte OpenAI. La connexion utilisée est celle de Codex sur ce Mac." : "Gérer le compte Claude dans le navigateur.")
                            .accessibilityLabel("Gérer le compte \(provider.title)")
                        Toggle(provider.title, isOn: Binding(get: { model.enabledProviders.contains(provider) },
                                                           set: { model.setEnabled($0, for: provider) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    if provider != Provider.allCases.last { Divider() }
                }
                Text("Les quotas disponibles apparaissent dans la barre. Connexion via Codex ou claude.ai.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            settingsSection("CONSOMMATION") {
                HStack(spacing: 12) {
                    ForecastIndicator(forecast: .margin, title: "Marge")
                    ForecastIndicator(forecast: .tight, title: "Faible")
                    ForecastIndicator(forecast: .depletion, title: "Surconsommation")
                }
                Text("À rythme constant jusqu’au reset. Jaune : 20 % de marge ou moins sur le quota restant.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Historique local sur 7 jours, sans adresse de compte. Les pics sont signalés dans le panneau.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if let error = model.trendStorageError { Text(error).foregroundStyle(.orange) }
            }
            if let error = model.settingsError { Text(error).foregroundStyle(.orange) }
            if model.helperPath.isEmpty { Text("Lecteur indisponible. Réinstalle QuotaBar.").foregroundStyle(.orange) }
            Text("QuotaBar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }.font(.system(size: 11))
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            content()
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func providerStatus(_ provider: Provider) -> String {
        guard model.enabledProviders.contains(provider) else { return "Désactivé" }
        if model.errors[provider] != nil { return "Connexion ou réseau à vérifier" }
        if let snapshot = model.snapshots[provider] {
            guard model.menuValues(now: model.displayDate)[provider] != nil else { return "Lecture à actualiser" }
            return snapshot.accountLabel ?? "Quota disponible"
        }
        return model.refreshing ? "Lecture en cours…" : "Pas encore de quota disponible"
    }

    @MainActor static func naturalSize(model: AppModel, width: CGFloat = 350) -> NSSize {
        let view = NSHostingView(rootView: Panel(model: model, width: width))
        let size = view.fittingSize
        return NSSize(width: width, height: ceil(size.height))
    }
}

private struct QuotaBarRow: View {
    let row: QuotaRow
    let mode: QuotaDisplayMode
    let ink: Color
    let now: Date
    let trend: QuotaTrend?
    let isFresh: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.title == "Session · 5 heures" ? "Session · 5 h" : row.title)
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .help(row.title)
                if let date = row.resetsAt {
                    Text(QuotaResetLabel.dateText(date))
                        .font(.system(size: 10)).foregroundStyle(date <= now ? Color.orange : Color.secondary)
                        .fixedSize()
                        .help(QuotaResetLabel.text(date, now: now))
                        .accessibilityLabel(QuotaResetLabel.text(date, now: now))
                } else {
                    Text("Date inconnue").font(.system(size: 10)).foregroundStyle(.secondary)
                        .help(row.resetDescription ?? "Le fournisseur ne donne pas la date de remise à zéro.")
                }
                Spacer(minLength: 4)
                Text(mode.percentage(row.remaining).map { "\($0) %" } ?? "Indisponible")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit().foregroundStyle(ink)
                    .fixedSize()
                    .accessibilityLabel(mode.percentage(row.remaining).map { "\($0) pour cent \(mode.qualifier)" } ?? "Indisponible")
            }
            let forecast = isFresh ? QuotaForecast.evaluate(remaining: row.remaining, resetsAt: row.resetsAt,
                                                   pointsPerHour: trend?.pointsPerHour,
                                                   observedSeconds: trend?.observedSeconds ?? 0, now: now) : .unavailable
            let awaitingObservation = isFresh && trend == nil && row.resetsAt.map { $0 > now } == true
                && row.remaining.map { (0...100).contains($0) } == true
            HStack(spacing: 5) {
                ForecastIndicator(forecast: forecast,
                                  title: forecast == .unavailable && awaitingObservation ? "Observation en cours" : nil)
                if let trend {
                    Text("· ≈ \(trend.pointsPerHour.formatted(.number.precision(.fractionLength(1)))) pts/h")
                        .monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityLabel("Environ \(trend.pointsPerHour.formatted(.number.precision(.fractionLength(1)))) points de quota par heure")
                    if let points = trend.spikePoints, let duration = trend.spikeSeconds {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help("Pic : \(points.formatted(.number.precision(.fractionLength(1)))) pts consommés en \(durationLabel(duration)). Rythme supérieur à 3 fois la moyenne des 2 heures précédentes.")
                            .accessibilityLabel("Pic récent de consommation")
                    }
                }
            }
            .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
            .help(forecastHelp(forecast))
        }
    }

    private func forecastHelp(_ forecast: QuotaForecast) -> String {
        if forecast == .exhausted { return "Le quota restant est nul. Attends le reset." }
        guard isFresh, let remaining = row.remaining, (0...100).contains(remaining),
              let reset = row.resetsAt, reset > now else { return "Prévision indisponible : quota ou date de reset à actualiser." }
        guard let trend else { return "Au moins deux intervalles et 30 minutes observées sont nécessaires. Les périodes sans lecture sont exclues." }
        let history = "\(durationLabel(trend.observedSeconds)) observées · \(durationLabel(trend.historySeconds)) d’historique."
        if forecast == .unavailable { return "Prévision indisponible : quota ou date de reset à actualiser. " + history }
        if forecast == .idle { return "Aucune consommation mesurée sur les intervalles observés. Cela ne prédit pas ta consommation future. " + history }
        return "Estimation si le rythme observé continue sans interruption jusqu’au reset. Vert : plus de 20 % du quota actuel restera. Jaune : de 0 à 20 %. Rouge : épuisement avant le reset. " + history
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes >= 1440 { return "\(minutes / 1440) j \((minutes % 1440) / 60) h" }
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) min" }
        return "\(minutes) min"
    }
}

private struct ForecastIndicator: View {
    let forecast: QuotaForecast
    var title: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    private var label: String {
        if let title { return title }
        switch forecast {
        case .margin: return "Marge confortable"
        case .tight: return "Marge faible"
        case .depletion: return "Surconsommation"
        case .exhausted: return "Quota épuisé"
        case .idle: return "Aucune conso observée"
        case .unavailable: return "Prévision indisponible"
        }
    }

    private var ink: Color {
        let dark = colorScheme == .dark
        switch forecast {
        case .margin: return dark ? Color(red: 0.44, green: 0.78, blue: 0.54) : Color(red: 0.18, green: 0.48, blue: 0.30)
        case .tight: return dark ? Color(red: 0.90, green: 0.70, blue: 0.25) : Color(red: 0.60, green: 0.40, blue: 0.03)
        case .depletion, .exhausted: return dark ? Color(red: 0.98, green: 0.53, blue: 0.46) : Color(red: 0.72, green: 0.23, blue: 0.20)
        case .idle, .unavailable: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ink).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(label).fontWeight(.medium)
        }.foregroundStyle(ink).accessibilityElement(children: .combine)
    }
}
