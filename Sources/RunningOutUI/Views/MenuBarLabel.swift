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
            if case .indexError = model.phase {
                // The numbers stopped updating: show that instead of a stale number (R-1). The accessible name
                // says what happened, and the popover offers Try Again.
                Image(systemName: "exclamationmark.triangle")
            } else {
                switch content {
                case .expiring(let minutes):
                    minutes == 0 ? Text("<1 min", bundle: .module) : Text("\(minutes) min", bundle: .module)
                case .share(let share):
                    Text(verbatim: Presentation.shareText(share))
                case .iconOnly:
                    EmptyView()
                }
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(content))
        .task { await model.startIfNeeded() }
    }

    private func accessibilityLabel(_ content: MenuBarContent) -> Text {
        switch model.phase {
        case .starting, .indexing:
            return Text("Tokens Are Running Out: reading Claude Code history", bundle: .module)
        case .noTranscripts:
            return Text("Tokens Are Running Out: no Claude Code history found", bundle: .module)
        case .indexError:
            return Text("Tokens Are Running Out: unable to read the usage index", bundle: .module)
        case .ready:
            break
        }
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
