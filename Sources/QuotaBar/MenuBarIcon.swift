import AppKit
import QuotaCore

@MainActor
enum MenuBarIcon {
    /// A single template image lets macOS tint both logos and percentages for either menu-bar theme.
    static func render(values: [Provider: String]) -> NSImage {
        let providers = Provider.allCases.filter { values[$0] != nil }
        guard !providers.isEmpty else {
            let image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "QuotaBar · aucun quota disponible") ?? NSImage(size: NSSize(width: 18, height: 18))
            image.isTemplate = true
            return image
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.black,
        ]
        let labels = providers.map { NSAttributedString(string: values[$0] ?? "--", attributes: attributes) }
        let width = labels.reduce(CGFloat(0)) { $0 + 20 + ceil($1.size().width) } + 12
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            var x: CGFloat = 0
            for (index, provider) in providers.enumerated() {
                // The official logos fill their whole box: 16 pt matches other menu-bar icons.
                Brand.image(provider).draw(in: NSRect(x: x, y: 3, width: 16, height: 16))
                x += 20
                let label = labels[index]
                label.draw(at: NSPoint(x: x, y: (22 - label.size().height) / 2))
                x += ceil(label.size().width) + 12
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
