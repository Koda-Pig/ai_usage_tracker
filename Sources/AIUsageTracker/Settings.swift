import Foundation

/// The two providers the app tracks, and the one preference per provider: whether its
/// column appears in the menu bar. Hidden providers still get a dropdown section, so the
/// toggle that brought them back is always within reach.
@MainActor
enum Settings {
    enum Provider: String, CaseIterable {
        case claude, codex

        var title: String {
            switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            }
        }

        /// SF Symbol drawn ahead of the percentages in the menu bar.
        var symbol: String {
            switch self {
            case .claude: "asterisk"
            case .codex: "terminal"
            }
        }
    }

    /// Shown unless the user has turned it off; a fresh install shows both.
    static func showsInMenuBar(_ provider: Provider) -> Bool {
        UserDefaults.standard.object(forKey: key(provider)) as? Bool ?? true
    }

    static func setShowsInMenuBar(_ shown: Bool, for provider: Provider) {
        UserDefaults.standard.set(shown, forKey: key(provider))
    }

    private static func key(_ provider: Provider) -> String { "showInMenuBar.\(provider.rawValue)" }
}
