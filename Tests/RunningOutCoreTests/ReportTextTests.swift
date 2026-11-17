import Foundation
import Testing

@testable import RunningOutCore

/// The CLI text must match `prototype/drain.py` character for character, so the number formats mirror
/// Python's `{:,}`, `{:.1%}`, `{:6.1%}` and `${:,.2f}`.
@Suite("ReportText")
struct ReportTextTests {
    @Test("money is dollars with thousands separators and two decimals")
    func money() {
        #expect(ReportText.money(616_334_000_000) == "$616.33")
        #expect(ReportText.money(1_234_567_891_000_000) == "$1,234,567.89")
        #expect(ReportText.money(0) == "$0.00")
    }

    @Test("percentages have one decimal, padded to a width when asked")
    func percent() {
        #expect(ReportText.percent(0.6579) == "65.8%")
        #expect(ReportText.percent(0.007, width: 6) == "  0.7%")
        #expect(ReportText.percent(1.0, width: 6) == "100.0%")
    }

    @Test("an empty report prints the header lines only, like the prototype")
    func emptyReport() {
        let text = ReportText.render(UsageReport(from: 0, to: 1), fromText: "A", toText: "B")
        // Joined from single-line literals: the prototype keeps trailing spaces ("tokens" with no
        // values, "0: " with no causes), and a formatter strips them from a multi-line literal.
        let expected = [
            "window              A .. B",
            "api calls           0",
            "tokens              ",
            "rebuilds            0 calls, 0 tokens (0.0% of cache writes)",
            "  in subagents      0",
            "  in main sessions  0: ",
            "  expired, short break  0 calls, 0 tokens",
            "  expired, long break   0 calls, 0 tokens",
            "cost (API list)     $0.00",
        ].joined(separator: "\n")
        #expect(text == expected)
    }
}
