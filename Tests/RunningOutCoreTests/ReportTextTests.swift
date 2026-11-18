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

    @Test("a full report prints every line in the prototype's format")
    func fullReport() {
        var report = UsageReport(from: 0, to: 1)
        report.calls = 4_133
        report.inputTokens = 1_234
        report.outputTokens = 56_789
        report.cacheReadTokens = 1_000_000
        report.cacheWriteTokens = 200_000
        report.rebuildCount = 5
        report.rebuildTokens = 150_000
        report.subagentRebuildCount = 1
        report.mainRebuildCounts = [.expiredShortBreak: 2, .expiredLongBreak: 1, .afterCompaction: 1]
        report.shortBreak = BreakTotals(count: 2, tokens: 70_000, cost: 100_000_000_000)
        report.longBreak = BreakTotals(count: 1, tokens: 50_000, cost: 150_000_000_000)
        report.totalCost = 1_000_000_000_000
        report.bucketCosts = [
            .normalWork: 400_000_000_000, .shortBreakRebuild: 100_000_000_000, .longBreakRebuild: 150_000_000_000,
            .sessionStartAndCompaction: 50_000_000_000, .subagents: 90_000_000_000, .advisor: 200_000_000_000,
            .modelChangeAndUpdate: 10_000_000_000, .unknown: 0,
        ]
        report.reducibleCost = 90_000_000_000
        report.advisor = AdvisorTotals(calls: 3, inputTokens: 150_000, outputTokens: 2_400, cost: 200_000_000_000)
        report.unpricedModels = ["claude-future-9": 2, "claude-a": 1]
        let expected = [
            "window              A .. B",
            "api calls           4,133",
            "tokens              input=1,234 output=56,789 cache_read=1,000,000 cache_write=200,000",
            "rebuilds            5 calls, 150,000 tokens (75.0% of cache writes)",
            "  in subagents      1",
            "  in main sessions  4: expired 3, after compaction 1",
            "  expired, short break  2 calls, 70,000 tokens",
            "  expired, long break   1 calls, 50,000 tokens",
            "cost (API list)     $1,000.00",
            "  normal work                  40.0%  $400.00",
            "  rebuild after short break    10.0%  $100.00",
            "  rebuild after long break     15.0%  $150.00",
            "  session start & compaction    5.0%  $50.00",
            "  subagents                     9.0%  $90.00",
            "  advisor                      20.0%  $200.00",
            "  model change & update         1.0%  $10.00",
            "  unknown                       0.0%  $0.00",
            "advisor calls       3, input=150,000 output=2,400",
            "menu bar (idle rebuilds) 25.0%",
            "reducible (short breaks) 9.0%",
            "unpriced models     claude-a x1, claude-future-9 x2",
        ].joined(separator: "\n")
        #expect(ReportText.render(report, fromText: "A", toText: "B") == expected)
    }
}
