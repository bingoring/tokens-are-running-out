import Foundation
import RunningOutCore

/// Strings built in code (notifications, accessibility labels). View text lives in the views; every string is
/// in `Localizable.xcstrings` with an English source and a Korean translation.
enum Copy {
    static func notificationTitle(minutes: Int) -> String {
        String(localized: "Cache expires in \(minutes) minutes", bundle: .module)
    }

    static func notificationBody(_ warning: ExpiryWarning) -> String {
        let title = warning.title ?? String(localized: "Untitled session", bundle: .module)
        let tokens = Presentation.tokens(warning.contextTokens)
        let cost = Presentation.money(warning.rebuildCost)
        return warning.priced
            ? String(
                localized:
                    "\(title): send a message to keep the cache. Otherwise the next message rebuilds it from \(tokens) tokens (about \(cost)).",
                bundle: .module)
            : String(
                localized:
                    "\(title): send a message to keep the cache. Otherwise the next message rebuilds it from \(tokens) tokens (an estimated \(cost)).",
                bundle: .module)
    }
}
