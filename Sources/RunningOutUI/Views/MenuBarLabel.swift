import RunningOutCore
import SwiftUI

/// The menu bar item: an hourglass and one number (2-3 BR-E8).
public struct MenuBarLabel: View {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        let content = Presentation.menuBar(
            warnings: model.warnings, today: model.todayReport, now: model.now.timeIntervalSince1970)
        HStack(spacing: 4) {
            Image(systemName: "hourglass")
            switch content {
            case .expiring(let minutes):
                minutes == 0 ? Text("<1 min", bundle: .module) : Text("\(minutes) min", bundle: .module)
            case .share(let share):
                Text(verbatim: Presentation.shareText(share))
            case .iconOnly:
                EmptyView()
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(content))
        .task { await model.startIfNeeded() }
    }

    private func accessibilityLabel(_ content: MenuBarContent) -> Text {
        switch content {
        case .expiring(let minutes):
            return Text(
                "Tokens Are Running Out: a session's cache expires in \(max(minutes, 1)) minutes", bundle: .module)
        case .share(let share):
            let percent = Presentation.shareText(share)
            return Text(
                "Tokens Are Running Out: \(percent) of today's cost went to rebuilding caches after a break",
                bundle: .module)
        case .iconOnly:
            return Text("Tokens Are Running Out: no usage today", bundle: .module)
        }
    }
}
