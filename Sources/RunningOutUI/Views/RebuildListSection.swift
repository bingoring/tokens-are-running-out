import RunningOutCore
import SwiftUI

/// "Expensive cache rebuilds" (2-3 BR-U4).
struct RebuildListSection: View {
    @Bindable var model: AppModel
    private let rowHeight: CGFloat = 44

    var body: some View {
        let rows = model.selectedReport.map {
            Presentation.rebuildRows($0, showAll: model.settings.showAllRebuildCauses)
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Expensive cache rebuilds", bundle: .module).font(.body.weight(.semibold))
                Spacer(minLength: 8)
                Toggle(
                    isOn: Binding(
                        get: { model.settings.showAllRebuildCauses },
                        set: { value in Task { await model.update { $0.showAllRebuildCauses = value } } })
                ) {
                    Text("Show all causes", bundle: .module)
                }
                .toggleStyle(.checkbox)
            }
            if let rows {
                if rows.isEmpty {
                    Text("No caches were rebuilt after a break in this period.", bundle: .module)

                    if !model.settings.showAllRebuildCauses {
                        Text("Turn on Show all causes to see other rebuilds.", bundle: .module)
                            .font(.callout)

                    }
                } else {
                    // Four and a half rows tall, so the next row peeks out when there are more.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(rows, id: \.messageID) { RebuildRow(event: $0) }
                        }
                    }
                    .frame(height: min(CGFloat(rows.count), 4.5) * (rowHeight + 8))
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
    }
}

struct RebuildRow: View {
    let event: RebuildEvent
    @State private var showingReason = false

    var body: some View {
        let time = RebuildText.time(event.timestamp)
        let summary = RebuildText.summary(event)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: time).monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                SessionTitle(title: event.title)
                Text(verbatim: summary).font(.callout).monospacedDigit()
                    .lineLimit(1).help(summary)
            }
            Spacer(minLength: 8)
            // A borderless icon button keeps the system focus ring; the name says what it opens.
            Button {
                showingReason = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help(Text("Show Reason", bundle: .module))
            .accessibilityLabel(
                Text(
                    "Show the reason for the \(time) rebuild in \(event.title ?? String(localized: "Untitled session", bundle: .module))",
                    bundle: .module)
            )
            .popover(isPresented: $showingReason, arrowEdge: .trailing) {
                RebuildDetailView(event: event)
            }
        }
        .frame(minHeight: 44, alignment: .top)
    }
}

/// Text shared by the rebuild row and the reason popover.
enum RebuildText {
    static func time(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        return Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func gap(_ seconds: Double) -> String {
        seconds < 3 * 3600
            ? Duration.seconds(seconds).formatted(
                .units(allowed: [.minutes], width: .abbreviated, fractionalPart: .hide(rounded: .up)))
            : Duration.seconds(seconds).formatted(
                .units(allowed: [.hours], width: .abbreviated, fractionalPart: .hide(rounded: .toNearestOrAwayFromZero))
            )
    }

    static func summary(_ event: RebuildEvent) -> String {
        let tokens = Presentation.tokens(event.cacheWriteTokens)
        let cost = Presentation.money(event.cacheWriteCost)
        switch event.cause {
        case .expiredShortBreak:
            let away = gap(event.gapSeconds ?? 0)
            return String(localized: "\(away) away · \(tokens) tokens · \(cost)", bundle: .module)
        case .expiredLongBreak:
            let away = gap(event.gapSeconds ?? 0)
            let context = Presentation.tokens(event.previousContextTokens ?? event.cacheWriteTokens)
            return String(localized: "\(away) away · context \(context) · \(cost)", bundle: .module)
        case .afterCompaction:
            return String(localized: "After compaction · \(tokens) tokens · \(cost)", bundle: .module)
        case .modelChanged:
            return String(localized: "Model changed · \(tokens) tokens · \(cost)", bundle: .module)
        case .versionChanged:
            return String(localized: "Claude Code updated · \(tokens) tokens · \(cost)", bundle: .module)
        case .sessionStart:
            return String(localized: "Session start · \(tokens) tokens · \(cost)", bundle: .module)
        case .unknown:
            return String(localized: "Unknown cause · \(tokens) tokens · \(cost)", bundle: .module)
        }
    }

    static func causeName(_ cause: RebuildCause) -> String {
        switch cause {
        case .sessionStart: return String(localized: "Session start", bundle: .module)
        case .afterCompaction: return String(localized: "After compaction", bundle: .module)
        case .modelChanged: return String(localized: "Model changed", bundle: .module)
        case .expiredShortBreak: return String(localized: "Cache rebuilt after a short break", bundle: .module)
        case .expiredLongBreak: return String(localized: "Cache rebuilt after a long break", bundle: .module)
        case .versionChanged: return String(localized: "Claude Code updated", bundle: .module)
        case .unknown: return String(localized: "Unknown cause", bundle: .module)
        }
    }
}
