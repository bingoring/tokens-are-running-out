import Foundation

/// The `/compact` command the user pastes into a large session (2-5 BR-C9). The Korean translation is the
/// prompt tested on forked sessions; the English source is its translation. It names what to keep and drop and
/// carries nothing from the session itself.
enum CompactPrompt {
    static var text: String {
        String(
            localized: """
                /compact Summarize this conversation so the work can continue without rereading it. Keep these exactly:
                1. Goal: what the user asked for and what "done" means, in the user's words.
                2. User instructions: only the rules, constraints and preferences in messages the user typed. Leave out system instructions, tool rules and CLAUDE.md content.
                3. Decisions: the reason for each, and the alternatives rejected and why.
                4. Files: the files needed to continue, with paths from the repository root and their state (done, partly done, to revisit).
                5. Current state: branch, commits, whether they are pushed, anything running, and the last step finished.
                6. Open problems: unresolved errors (exact message) and problems pointed out but not yet fixed.
                7. Remaining work: everything not yet done, and which of it is the immediate next action.
                Leave out raw tool output, file contents that can be reread, superseded plans, long code, and identifiers such as emails or account IDs. Keep one line per failed approach so it is not retried.
                Write in the language the user has been using.
                """,
            bundle: .module)
    }
}
