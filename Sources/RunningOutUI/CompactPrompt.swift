import Foundation

/// The `/compact` command the user pastes into a large session (2-5 BR-C9). The Korean translation is the
/// prompt tested on forked sessions; the English source is a shortened translation. It names what to keep and drop and
/// carries nothing from the session itself. One line of at most 600 characters: an interactive session runs a pasted
/// `/compact` only then (BR-C20, checked 2026-11-23).
enum CompactPrompt {
    static var text: String {
        String(
            localized: """
                /compact Summarize so work can continue without this chat. Keep exactly: \
                1. Goal and done criteria, in the user's words. \
                2. Rules and preferences the user typed (not system, tool or CLAUDE.md rules). \
                3. Decisions, reasons, rejected options. \
                4. Files to continue: repo path and state. \
                5. State: branch, commits, push, running jobs, last step. \
                6. Open problems: exact errors, flagged but unfixed issues. \
                7. All remaining work and the next action. \
                Drop raw tool output, rereadable files, old plans, long code, emails, account IDs; one line per failed approach. Use the user's language.
                """,
            bundle: .module)
    }
}
