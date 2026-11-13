import AppKit
import UsageCore

/// The menu bar glyph: per provider, the remaining 5-hour % stacked over the remaining weekly %.
/// A template image, so macOS tints it for light/dark/highlighted menu bars. Redrawn only when data changes.
@MainActor
enum StatusImage {
    struct Column {
        let symbol: String
        let top: String       // 5-hour
        let bottom: String    // weekly
    }

    /// Only the providers the user keeps in the menu bar get a column.
    static func columns(claude: ProviderStatus, codex: ProviderStatus, now: Date = Date()) -> [Column] {
        func pct(_ w: UsageWindow?) -> String {
            guard let w else { return "–" }
            return "\(Int(w.remainingPercent(at: now).rounded()))%"
        }
        return Settings.Provider.allCases.compactMap { provider in
            guard Settings.showsInMenuBar(provider) else { return nil }
            let status = provider == .claude ? claude : codex
            return Column(symbol: provider.symbol, top: pct(status.usage?.fiveHour), bottom: pct(status.usage?.weekly))
        }
    }

    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    private static let symbolGap: CGFloat = 2
    private static let columnGap: CGFloat = 7

    static func render(_ columns: [Column]) -> NSImage {
        // With both providers hidden there is nothing to draw, and a zero-width status item
        // can't be clicked — so keep a neutral mark that still opens the menu.
        guard !columns.isEmpty else { return placeholder() }

        let height = NSStatusBar.system.thickness
        let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.black]
        let symbols = columns.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) }
        let widths = columns.indices.map { i -> CGFloat in
            let text = max(columns[i].top.size(withAttributes: attrs).width, columns[i].bottom.size(withAttributes: attrs).width)
            return (symbols[i]?.size.width ?? 0) + symbolGap + ceil(text)
        }
        let width = widths.reduce(0, +) + columnGap * CGFloat(max(columns.count - 1, 0))

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            let lineHeight = numberFont.ascender - numberFont.descender
            for (i, column) in columns.enumerated() {
                if let symbol = symbols[i] {
                    symbol.draw(in: NSRect(x: x, y: (height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
                    x += symbol.size.width + symbolGap
                }
                let mid = height / 2
                column.top.draw(at: NSPoint(x: x, y: mid - 1), withAttributes: attrs)
                column.bottom.draw(at: NSPoint(x: x, y: mid - lineHeight + 1), withAttributes: attrs)
                x = widths[0...i].reduce(0, +) + columnGap * CGFloat(i + 1)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func placeholder() -> NSImage {
        let image = NSImage(systemSymbolName: "percent", accessibilityDescription: "AI allowance remaining")?
            .withSymbolConfiguration(symbolConfig) ?? NSImage(size: NSSize(width: 12, height: 12))
        image.isTemplate = true
        return image
    }
}
