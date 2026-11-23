import AppKit
import RunningOutCore
import SwiftUI

/// The popover (2-3 frontend-components §1). Groups are 16 pt apart, rows within a group 8 pt.
public struct PopoverView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    /// The popover's maximum height; nil means 80% of the screen's visible height (2-3 frontend-components §1).
    private let maxHeight: CGFloat?

    /// Room for the padding, the divider and the Settings and Quit row below the scrolling content.
    private static let footerAllowance: CGFloat = 100

    /// 80% of the visible height of the screen with the menu bar.
    private static var defaultMaxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 1_000) * 0.8 }

    public init(model: AppModel, maxHeight: CGFloat? = nil) {
        self.model = model
        self.maxHeight = maxHeight
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // The content scrolls once the popover reaches its maximum height; the footer below stays on screen.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            // As tall as the content up to the cap, whatever height the window proposes: the menu bar window can
            // propose less than the content, and a scroll view that takes the proposal shows nothing (v0.2.0).
            .frame(maxHeight: (maxHeight ?? Self.defaultMaxHeight) - Self.footerAllowance)
            .fixedSize(horizontal: false, vertical: true)
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
                    warnings: active, now: model.now, notificationsOn: model.settings.notifyBeforeExpiry,
                    copy: { model.copyCompactPrompt() })
            }
            if !model.largeSessions.isEmpty {
                LargeSessionsSection(sessions: model.largeSessions, copy: { model.copyCompactPrompt() })
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
    let copy: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Caches expiring soon", bundle: .module).font(.body.weight(.semibold))
            // At most five rows, so the popover never grows past the screen.
            ForEach(Array(warnings.prefix(5).enumerated()), id: \.element.sessionID) { index, warning in
                ExpiryWarningRow(
                    warning: warning, now: now, showsAdvice: index == 0, notificationsOn: notificationsOn,
                    showsCompactHint: Presentation.showsCompactHint(warning, isFirst: index == 0), copy: copy)
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
    var showsCompactHint = false
    var copy: () -> Bool = { false }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            details
            // Outside the combined element, so the button stays its own VoiceOver and keyboard stop (2-5 BR-C14).
            if showsCompactHint {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(
                        "Compact it before you leave, and only the summary is rebuilt when you come back.",
                        bundle: .module
                    )
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    CopyCompactPromptButton(title: warning.title, copy: copy)
                }
            }
        }
    }

    private var details: some View {
        let minutes = Presentation.minutesLeft(until: warning.expiresAt, now: now.timeIntervalSince1970)
        return VStack(alignment: .leading, spacing: 4) {
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
