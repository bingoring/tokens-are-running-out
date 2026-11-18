import AppKit
import RunningOutCore
import SwiftUI

/// The popover (2-3 frontend-components §1). Groups are 16 pt apart, rows within a group 8 pt.
public struct PopoverView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
            Divider()
            HStack {
                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Text("Settings…", bundle: .module)
                }
                .keyboardShortcut(",")
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("Quit", bundle: .module)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { model.popoverVisible = true }
        .onDisappear { model.popoverVisible = false }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .starting:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                .accessibilityLabel(Text("Loading", bundle: .module))
        case .indexing(let progress):
            IndexingBanner(progress: progress)
        case .noTranscripts:
            Text(
                "No Claude Code history found. Use Claude Code once, and your usage will appear here.", bundle: .module
            )
            .fixedSize(horizontal: false, vertical: true)
        case .indexError:
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Unable to read the usage index. Check that your disk has free space, then try again.",
                    bundle: .module
                )
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await model.retry() }
                } label: {
                    Text("Try Again", bundle: .module)
                }
            }
        case .ready:
            if model.health.kind != .none {
                FormatChangeBanner(kind: model.health.kind) { model.openReleasesPage() }
            }
            let active = Presentation.activeWarnings(model.warnings, now: model.now.timeIntervalSince1970)
            if !active.isEmpty {
                ExpiringSessionsSection(
                    warnings: active, now: model.now, notificationsOn: model.settings.notifyBeforeExpiry)
            }
            BreakdownSection(model: model)
            RebuildListSection(model: model)
        }
    }
}

struct IndexingBanner: View {
    let progress: IndexProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let done = Int64(progress.bytesRead).formatted(.byteCount(style: .file))
            let total = Int64(progress.bytesTotal).formatted(.byteCount(style: .file))
            Text("Reading Claude Code history… \(done) of \(total)", bundle: .module)
            ProgressView(value: Double(progress.bytesRead), total: Double(max(progress.bytesTotal, 1)))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct FormatChangeBanner: View {
    let kind: IndexHealth.Kind
    let openReleases: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                switch kind {
                case .unreadableLines(let share):
                    let percent = Presentation.shareText(share)
                    Text(
                        "Claude Code's history format may have changed: \(percent) of Claude's replies from the last 7 days couldn't be read, so numbers may be low. Update Tokens Are Running Out to the latest version.",
                        bundle: .module)
                case .noCalls, .none:
                    Text(
                        "Claude Code's history format may have changed: no usage could be read from the last 7 days. Update Tokens Are Running Out to the latest version.",
                        bundle: .module)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            .fixedSize(horizontal: false, vertical: true)
            Button(action: openReleases) { Text("Open Releases Page", bundle: .module) }
        }
    }
}

// MARK: - Caches expiring soon

struct ExpiringSessionsSection: View {
    let warnings: [ExpiryWarning]
    let now: Date
    let notificationsOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Caches expiring soon", bundle: .module).font(.body.weight(.semibold))
            // At most five rows, so the popover never grows past the screen.
            ForEach(Array(warnings.prefix(5).enumerated()), id: \.element.sessionID) { index, warning in
                ExpiryWarningRow(
                    warning: warning, now: now, showsAdvice: index == 0, notificationsOn: notificationsOn)
            }
            if warnings.count > 5 {
                Text("\(warnings.count - 5) more sessions", bundle: .module).font(.callout)
            }
        }
    }
}

struct ExpiryWarningRow: View {
    let warning: ExpiryWarning
    let now: Date
    let showsAdvice: Bool
    let notificationsOn: Bool

    var body: some View {
        let minutes = Presentation.minutesLeft(until: warning.expiresAt, now: now.timeIntervalSince1970)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SessionTitle(title: warning.title)
                Spacer(minLength: 8)
                if warning.status == .idle {
                    Label {
                        minutes == 0
                            ? Text("Less than a minute left", bundle: .module)
                            : Text("\(minutes) min left", bundle: .module)
                    } icon: {
                        Image(systemName: "clock").foregroundStyle(.orange)
                    }
                    .monospacedDigit()
                } else {
                    Label {
                        Text("Status unknown", bundle: .module)
                    } icon: {
                        Image(systemName: "questionmark.circle")
                    }
                    .help(
                        warning.status == .unreadable
                            ? Text(
                                "Claude Code's running-session files can't be read, so this session may already be busy.",
                                bundle: .module)
                            : Text(
                                "Claude Code reports a status this version doesn't know, so this session may already be busy.",
                                bundle: .module))
                }
            }
            if showsAdvice {
                let tokens = Presentation.tokens(warning.contextTokens)
                let cost = Presentation.money(warning.rebuildCost)
                Group {
                    if warning.priced {
                        Text(
                            "To continue without a rebuild, send a message within \(max(minutes, 1)) minutes. After that, the next message rebuilds the cache from \(tokens) tokens (about \(cost)).",
                            bundle: .module)
                    } else {
                        Text(
                            "To continue without a rebuild, send a message within \(max(minutes, 1)) minutes. After that, the next message rebuilds the cache from \(tokens) tokens (an estimated \(cost); this model has no listed price).",
                            bundle: .module)
                    }
                }
                .font(.callout)

                .fixedSize(horizontal: false, vertical: true)
            }
            if notificationsOn, warning.ttl == .fiveMinutes {
                Text("No notification: this session uses a 5-minute cache.", bundle: .module)
                    .font(.callout)

            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One line; the full title is in the tooltip (frontend-components: truncate with a way back).
struct SessionTitle: View {
    let title: String?

    var body: some View {
        if let title {
            Text(verbatim: title).lineLimit(1).truncationMode(.tail).help(title)
        } else {
            Text("Untitled session", bundle: .module).lineLimit(1)
        }
    }
}
