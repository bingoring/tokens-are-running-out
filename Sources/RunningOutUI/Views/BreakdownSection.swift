import RunningOutCore
import SwiftUI

/// "What used your tokens" (2-3 BR-U1 to BR-U3).
struct BreakdownSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What used your tokens", bundle: .module).font(.body.weight(.semibold))
            Picker(
                selection: Binding(
                    get: { model.settings.selectedPeriod },
                    set: { period in Task { await model.update { $0.selectedPeriod = period } } })
            ) {
                Text("5 hours", bundle: .module).tag(ReportPeriod.last5Hours)
                Text("Today", bundle: .module).tag(ReportPeriod.today)
                Text("7 days", bundle: .module).tag(ReportPeriod.last7Days)
            } label: {
                Text("Period", bundle: .module)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let report = model.selectedReport {
                if report.totalCost == 0 {
                    Text("No usage in this period.", bundle: .module)
                } else {
                    summary(report)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Presentation.breakdown(report)) { row in
                            if row.kind == .other {
                                OtherRows(row: row)
                            } else {
                                BreakdownRowView(row: row, note: row.kind == .shortBreak ? reducible(report) : nil)
                            }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small).accessibilityLabel(Text("Loading", bundle: .module))
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.isComputing {
                ProgressView().controlSize(.mini).accessibilityLabel(Text("Updating", bundle: .module))
            }
        }
    }

    @ViewBuilder private func summary(_ report: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let total = Presentation.money(report.totalCost)
            Text("\(total) at API list prices · \(report.calls) calls", bundle: .module).monospacedDigit()
            let idle = Presentation.shareText(report.idleRebuildShare)
            Text("\(idle) went to rebuilding caches after a break.", bundle: .module).monospacedDigit()
            if !report.unpricedModels.isEmpty {
                Text("Some calls used a model without a listed price, so these amounts are estimates.", bundle: .module)
            }
            if !model.settings.usesDefaultRebuildThreshold {
                let threshold = Presentation.tokens(model.settings.rebuildThresholdTokens)
                Text("Counting cache rebuilds of \(threshold) tokens or more (changed in Settings).", bundle: .module)
            }
        }
        .font(.callout)

    }

    private func reducible(_ report: UsageReport) -> String? {
        guard report.reducibleCost > 0 else { return nil }
        let share = Presentation.shareText(report.reducibleShare)
        return String(
            localized: "\(share) could have been saved by continuing before the cache expired", bundle: .module)
    }
}

/// Label, share and amount on one line, the bar below; read as one element (the bar is hidden from VoiceOver).
struct BreakdownRowView: View {
    let row: BreakdownRow
    var note: String?
    var showsBar = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            BreakdownLine(row: row) { BreakdownLabel(kind: row.kind) }
            if showsBar {
                ProgressView(value: row.share).tint(.secondary).accessibilityHidden(true)
            }
            if let note {
                Label {
                    Text(verbatim: note).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb").foregroundStyle(.tint)
                }
                .font(.callout)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The label wraps or truncates; the numbers keep their own width so amounts line up.
struct BreakdownLine<Label: View>: View {
    let row: BreakdownRow
    @ViewBuilder let label: () -> Label

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            label().frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: Presentation.shareText(row.share)).monospacedDigit()
            Text(verbatim: Presentation.money(row.cost)).monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
        }
    }
}

/// "Other" with its three causes in a native disclosure group (design review HIGH: reachable content).
struct OtherRows: View {
    let row: BreakdownRow
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(row.children) { child in
                        BreakdownRowView(row: child, showsBar: false)
                    }
                }
                .padding(.top, 4)
            } label: {
                BreakdownLine(row: row) { BreakdownLabel(kind: .other) }
            }
            ProgressView(value: row.share).tint(.secondary).accessibilityHidden(true)
        }
    }
}

struct BreakdownLabel: View {
    let kind: BreakdownRow.Kind

    var body: some View {
        switch kind {
        case .normalWork: Text("Normal work", bundle: .module)
        case .shortBreak: Text("Cache rebuilt after a short break", bundle: .module)
        case .longBreak: Text("Cache rebuilt after a long break", bundle: .module)
        case .subagents: Text("Subagents", bundle: .module)
        case .advisor: Text("Advisor", bundle: .module)
        case .other: Text("Other", bundle: .module)
        case .sessionStartAndCompaction: Text("Session start and compaction", bundle: .module)
        case .modelChangeAndUpdate: Text("Model change and update", bundle: .module)
        case .unknown: Text("Unknown cause", bundle: .module)
        }
    }
}
