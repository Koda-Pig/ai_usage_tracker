import AppKit
import UsageCore

/// The menu bar glyph: per provider, a symbol followed by the 5-hour % stacked over the weekly %.
/// A template image, so macOS tints it for light/dark/highlighted menu bars. Redrawn only when data changes.
@MainActor
enum StatusImage {
    struct Column {
        let symbol: String
        let top: String       // 5-hour
        let bottom: String    // weekly
    }

    static func columns(claude: ProviderStatus, codex: ProviderStatus, now: Date = Date()) -> [Column] {
        func pct(_ w: UsageWindow?) -> String {
            guard let w else { return "–" }
            return "\(Int(w.percent(at: now).rounded()))%"
        }
        return [
            Column(symbol: "asterisk", top: pct(claude.usage?.fiveHour), bottom: pct(claude.usage?.weekly)),
            Column(symbol: "terminal", top: pct(codex.usage?.fiveHour), bottom: pct(codex.usage?.weekly)),
        ]
    }

    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    private static let symbolGap: CGFloat = 2
    private static let columnGap: CGFloat = 7

    static func render(_ columns: [Column]) -> NSImage {
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
}
