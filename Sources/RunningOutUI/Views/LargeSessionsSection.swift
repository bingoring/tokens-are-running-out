import RunningOutCore
import SwiftUI

// MARK: - Large sessions (2-5 frontend-components ①)

/// Running sessions with a large context, each with a button that copies the compact prompt.
struct LargeSessionsSection: View {
    let sessions: [LargeSession]
    let copy: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Large sessions", bundle: .module).font(.body.weight(.semibold))
            // At most five rows, like the warnings, so the popover never grows past the screen.
            ForEach(sessions.prefix(5), id: \.sessionID) { session in
                LargeSessionRow(session: session, copy: copy)
            }
            if sessions.count > 5 {
                Text("\(sessions.count - 5) more sessions", bundle: .module).font(.callout)
            }
            Text("Paste it into the session and press Return. It works best when a task is done.", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LargeSessionRow: View {
    let session: LargeSession
    let copy: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SessionTitle(title: session.title)
                Spacer(minLength: 8)
                CopyCompactPromptButton(title: session.title, copy: copy)
            }
            HStack(spacing: 4) {
                Text(verbatim: Presentation.largeSessionDetail(session))
                if session.status == .unreadable {
                    Image(systemName: "questionmark.circle")
                        .help(
                            Text(
                                "Claude Code's running-session files can't be read, so this session may have ended.",
                                bundle: .module)
                        )
                        .accessibilityLabel(Text("Status unknown", bundle: .module))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

/// Copies the compact prompt. The label reads Copied for two seconds after the last press, and VoiceOver hears
/// it; a failed copy changes nothing (2-5 BR-C11, BR-C12). No animation: it is a frequent action.
struct CopyCompactPromptButton: View {
    let title: String?
    let copy: () -> Bool
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button {
            guard copy() else { return }
            copied = true
            AccessibilityNotification.Announcement(String(localized: "Compact prompt copied", bundle: .module)).post()
            reset?.cancel()
            reset = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            // Both labels take space, so the button keeps its width when the label changes.
            ZStack {
                Text("Copy compact prompt", bundle: .module).opacity(copied ? 0 : 1)
                Label {
                    Text("Copied", bundle: .module)
                } icon: {
                    Image(systemName: "checkmark")
                }
                .opacity(copied ? 1 : 0)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help(
            Text(
                "Copies a /compact command that keeps the goal, decisions, files, state and remaining work.",
                bundle: .module)
        )
        .accessibilityLabel(
            Text(
                "Copy compact prompt for \(title ?? String(localized: "Untitled session", bundle: .module))",
                bundle: .module))
    }
}
