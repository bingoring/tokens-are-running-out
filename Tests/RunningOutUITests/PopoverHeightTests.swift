import AppKit
import RunningOutCore
import SwiftUI
import Testing

@testable import RunningOutUI

/// The popover is at most 80% of the screen tall (2-3 frontend-components §1), so Settings and Quit stay on
/// screen; a short popover keeps its natural height.
@MainActor
@Suite("Popover height")
struct PopoverHeightTests {
    private let now = Date(timeIntervalSince1970: 1_794_268_800)

    private func height(_ model: AppModel, maxHeight: CGFloat) -> CGFloat {
        _ = NSApplication.shared
        return NSHostingView(rootView: PopoverView(model: model, maxHeight: maxHeight)).fittingSize.height
    }

    private func tall() -> AppModel {
        let t = now.timeIntervalSince1970
        let warnings = (0..<7).map { n in
            ExpiryWarning(
                sessionID: "w\(n)", title: "Session \(n + 1)", expiresAt: t + Double(10 + n) * 60, ttl: .oneHour,
                contextTokens: 300_000, rebuildCost: 2_400_000_000, model: "claude-opus-5-5", priced: true,
                status: .idle)
        }
        let large = (0..<7).map { n in
            LargeSession(
                sessionID: "l\(n)", title: "Session \(n + 1)", contextTokens: 300_000, readCost: 60_000_000,
                model: "claude-opus-5-5", priced: true, status: .running)
        }
        return .preview(phase: .ready, now: now, warnings: warnings, largeSessions: large)
    }

    @Test("a tall popover stops at its maximum height and scrolls")
    func tallPopoverIsCapped() {
        let natural = height(tall(), maxHeight: 10_000)
        #expect(natural > 500)
        #expect(height(tall(), maxHeight: 500) <= 500)
    }

    /// The menu bar window can propose a height smaller than the content; the content must not shrink to fit it.
    /// v0.2.0 shipped with the scroll area taking the proposal, so the popover showed only Settings and Quit.
    @Test("a small proposed height does not collapse the content")
    func smallProposalDoesNotCollapse() {
        _ = NSApplication.shared
        let short = AppModel.preview(phase: .noTranscripts, now: now)
        let natural = height(short, maxHeight: 10_000)
        let controller = NSHostingController(rootView: PopoverView(model: short, maxHeight: 10_000))
        let proposed = controller.sizeThatFits(in: CGSize(width: 360, height: 40))
        #expect(proposed.height == natural)

        let capped = NSHostingController(rootView: PopoverView(model: tall(), maxHeight: 500))
            .sizeThatFits(in: CGSize(width: 360, height: 40))
        #expect(capped.height > 400 && capped.height <= 500)
    }

    @Test("a short popover keeps its natural height")
    func shortPopoverKeepsItsHeight() {
        let short = AppModel.preview(phase: .noTranscripts, now: now)
        let natural = height(short, maxHeight: 10_000)
        #expect(natural > 60)
        #expect(height(short, maxHeight: 500) == natural)
    }
}
