import RunningOutCore
import SwiftUI

/// Why a rebuild was counted under its cause: the evidence and the rule (design 8.1 "분류 근거 보기").
public struct RebuildDetailView: View {
    let event: RebuildEvent

    public init(event: RebuildEvent) { self.event = event }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: RebuildText.causeName(event.cause)).font(.body.weight(.semibold))
                if let title = event.title {
                    Text(verbatim: title).fixedSize(horizontal: false, vertical: true)
                }
                Text(
                    verbatim: Date(timeIntervalSince1970: event.timestamp).formatted(
                        date: .abbreviated, time: .shortened)
                )

            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Previous call", bundle: .module)
                    if let previous = event.previousTimestamp, let gap = event.gapSeconds {
                        let time = RebuildText.time(previous)
                        let earlier = RebuildText.gap(gap)
                        Text("\(time) (\(earlier) earlier)", bundle: .module)
                    } else {
                        Text("None", bundle: .module)
                    }
                }
                GridRow {
                    Text("Cache lifetime", bundle: .module)
                    event.previousTTL == .oneHour ? Text("1 hour", bundle: .module) : Text("5 minutes", bundle: .module)
                }
                GridRow {
                    Text("Model", bundle: .module)
                    change(from: event.previousModel, to: event.model)
                }
                GridRow {
                    Text("Claude Code", bundle: .module)
                    change(from: event.previousVersion, to: event.version ?? "?")
                }
            }
            .monospacedDigit()
            rule.fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                let tokens = Presentation.tokens(event.cacheWriteTokens)
                let cost = Presentation.money(event.cacheWriteCost)
                Text("Rebuilt \(tokens) tokens · \(cost) at API list prices", bundle: .module)
                if event.cause == .expiredShortBreak {
                    let instead = Presentation.money(event.cacheWriteCost - event.reducibleCost)
                    Label {
                        Text("Continuing before the cache expired would have cost \(instead) instead.", bundle: .module)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lightbulb").foregroundStyle(.tint)
                    }
                }
            }
            .monospacedDigit()
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder private func change(from previous: String?, to current: String) -> some View {
        if let previous, previous != current {
            Text("\(current) (was \(previous))", bundle: .module)
        } else {
            Text("\(current) (unchanged)", bundle: .module)
        }
    }

    @ViewBuilder private var rule: some View {
        let lifetime =
            event.previousTTL == .oneHour ? Text("1-hour", bundle: .module) : Text("5-minute", bundle: .module)
        let gap = RebuildText.gap(event.gapSeconds ?? 0)
        switch event.cause {
        case .expiredShortBreak:
            Text(
                "The gap (\(gap)) was longer than the \(lifetime) cache lifetime, so the cache had expired. Gaps up to 3 hours count as short breaks.",
                bundle: .module)
        case .expiredLongBreak:
            Text(
                "The gap (\(gap)) was longer than the \(lifetime) cache lifetime, so the cache had expired. Gaps over 3 hours count as long breaks.",
                bundle: .module)
        case .afterCompaction:
            Text("The conversation was compacted just before this call, which starts a new cache.", bundle: .module)
        case .modelChanged:
            Text("The model changed, and each model keeps its own cache.", bundle: .module)
        case .versionChanged:
            Text("Claude Code was updated between these calls, and the cache was rebuilt.", bundle: .module)
        case .unknown, .sessionStart:
            Text("None of the known causes explains this rebuild.", bundle: .module)
        }
    }
}
