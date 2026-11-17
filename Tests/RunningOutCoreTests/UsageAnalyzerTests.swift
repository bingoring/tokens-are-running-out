import Foundation
import Testing

@testable import RunningOutCore

/// Expected costs are worked out by hand in nano-USD from the official prices
/// (Opus 5.5: 1h write 8000, read 200, output 20000; Fable 5.2: 1h write 16000;
/// Sonnet 5.5: 5m write 2500, read 100), in thousandths of a USD per million tokens.
@Suite("UsageAnalyzer")
struct UsageAnalyzerTests {
    private let nov10: Double = 1_794_268_800  // 2026-11-10T00:00:00Z

    private func makeReport() throws -> UsageReport {
        let dir = try TempDir()
        try dir.write(
            Fixture.title("결제 화면 개편", session: "s1")
                // session start: write 60,000 -> 480,000,000
                + Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1", input: 0, output: 0, write: 60_000)
                // normal: 100 x 8000 + 60,000 x 200 = 12,800,000
                + Fixture.call(
                    id: "m2", at: "2026-11-10T00:01:40Z", session: "s1", input: 0, output: 0, read: 60_000, write: 100)
                // 3,601 s later: short-break expiry, write 70,000 -> 560,000,000, reducible 560,000,000 - 14,000,000
                + Fixture.call(id: "m3", at: "2026-11-10T01:01:41Z", session: "s1", input: 0, output: 0, write: 70_000)
                // model change to Fable 5.2: 60,000 x 16000 = 960,000,000
                + Fixture.call(
                    id: "m4", at: "2026-11-10T01:01:51Z", session: "s1", model: "claude-fable-5-2", input: 0,
                    output: 0, write: 60_000),
            to: "projects/-p/s1.jsonl")
        try dir.write(
            // subagent rebuild: 60,000 x 2500 = 150,000,000; then 10,000 x 100 = 1,000,000
            Fixture.call(
                id: "a1", at: "2026-11-10T00:30:00Z", session: "s1", model: "claude-sonnet-5-5", input: 0, output: 0,
                write: 60_000, ttl: "5m")
                + Fixture.call(
                    id: "a2", at: "2026-11-10T00:31:00Z", session: "s1", model: "claude-sonnet-5-5", input: 0,
                    output: 0, read: 10_000),
            to: "projects/-p/s1/subagents/agent-a.jsonl")
        try dir.write(
            // unknown model priced as Opus 5.5: 1,000 output x 20000 = 20,000,000
            Fixture.call(
                id: "u1", at: "2026-11-10T00:10:00Z", session: "s2", model: "claude-future-9", input: 0, output: 1_000),
            to: "projects/-p/s2.jsonl")
        let indexer = try Indexer(
            root: dir.url.appendingPathComponent("projects"),
            databaseURL: dir.url.appendingPathComponent("index.sqlite"))
        try indexer.indexAll()
        return try UsageAnalyzer(indexer: indexer, prices: PriceTable.bundled()).report(
            from: nov10, to: nov10 + 86_400)
    }

    @Test("costs land in the bucket of their cause and add up to the total")
    func buckets() throws {
        let report = try makeReport()
        #expect(report.totalCost == 2_183_800_000)
        #expect(report.bucketCosts[.normalWork] == 32_800_000)
        #expect(report.bucketCosts[.shortBreakRebuild] == 560_000_000)
        #expect(report.bucketCosts[.longBreakRebuild] == 0)
        #expect(report.bucketCosts[.sessionStartAndCompaction] == 480_000_000)
        #expect(report.bucketCosts[.subagents] == 151_000_000)
        #expect(report.bucketCosts[.modelChangeAndUpdate] == 960_000_000)
        #expect(report.bucketCosts[.unknown] == 0)
        #expect(report.bucketCosts.values.reduce(0, +) == report.totalCost)
    }

    @Test("the menu bar share and the reducible share follow from the short and long break rebuilds")
    func shares() throws {
        let report = try makeReport()
        #expect(report.idleRebuildShare == 560_000_000.0 / 2_183_800_000.0)
        #expect(report.reducibleShare == 546_000_000.0 / 2_183_800_000.0)
        #expect(report.shortBreak == BreakTotals(count: 1, tokens: 70_000, cost: 560_000_000))
        #expect(report.longBreak == BreakTotals(count: 0, tokens: 0, cost: 0))
    }

    @Test("rebuilds are counted by cause, subagents separately")
    func counts() throws {
        let report = try makeReport()
        #expect(report.calls == 7)
        #expect(report.rebuildCount == 4)
        #expect(report.subagentRebuildCount == 1)
        #expect(report.mainRebuildCounts == [.sessionStart: 1, .expiredShortBreak: 1, .modelChanged: 1])
        #expect(report.unpricedModels == ["claude-future-9": 1])
    }

    @Test("main-session rebuilds are listed in time order with the evidence for their cause")
    func rebuildList() throws {
        let report = try makeReport()
        #expect(report.rebuilds.map(\.messageID) == ["m1", "m3", "m4"])
        let expired = try #require(report.rebuilds.first { $0.messageID == "m3" })
        #expect(expired.cause == .expiredShortBreak)
        #expect(expired.title == "결제 화면 개편")
        #expect(expired.sessionID == "s1")
        #expect(expired.gapSeconds == 3_601)
        #expect(expired.previousTimestamp == nov10 + 100)
        #expect(expired.previousTTL == .oneHour)
        #expect(expired.cacheWriteTokens == 70_000)
        #expect(expired.cacheWriteCost == 560_000_000)
        #expect(expired.reducibleCost == 546_000_000)
        let start = try #require(report.rebuilds.first)
        #expect(start.previousTimestamp == nil)
        #expect(start.reducibleCost == 0)
    }

    @Test("an empty window reports zeros")
    func emptyWindow() throws {
        let dir = try TempDir()
        try dir.write(Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1"), to: "projects/-p/s1.jsonl")
        let indexer = try Indexer(
            root: dir.url.appendingPathComponent("projects"),
            databaseURL: dir.url.appendingPathComponent("index.sqlite"))
        try indexer.indexAll()
        let report = try UsageAnalyzer(indexer: indexer, prices: PriceTable.bundled()).report(from: 0, to: 1)
        #expect(report.calls == 0)
        #expect(report.totalCost == 0)
        #expect(report.idleRebuildShare == 0)
        #expect(report.rebuilds.isEmpty)
    }

    private func report(of dir: TempDir) throws -> UsageReport {
        let indexer = try Indexer(
            root: dir.url.appendingPathComponent("projects"),
            databaseURL: dir.url.appendingPathComponent("index.sqlite"))
        try indexer.indexAll()
        return try UsageAnalyzer(indexer: indexer, prices: PriceTable.bundled()).report(
            from: nov10, to: nov10 + 86_400)
    }

    @Test("a rebuild's cache write goes to its cause and the rest of that call to normal work")
    func rebuildSplit() throws {
        let dir = try TempDir()
        // Session start: write 60,000 x 8000 = 480,000,000; input 1,000 x 4000 + output 2,000 x 20000 = 44,000,000.
        try dir.write(
            Fixture.call(
                id: "m1", at: "2026-11-10T00:00:00Z", session: "s1", input: 1_000, output: 2_000, write: 60_000),
            to: "projects/-p/s1.jsonl")
        let report = try report(of: dir)
        #expect(report.bucketCosts[.sessionStartAndCompaction] == 480_000_000)
        #expect(report.bucketCosts[.normalWork] == 44_000_000)
    }

    @Test("an advisor consult is charged at the advisor's prices in its call's bucket and also totalled apart")
    func advisorCost() throws {
        let dir = try TempDir()
        // Session start: Opus 5.5 write 60,000 x 8000 = 480,000,000.
        // Normal work: Fable 5.2 advisor input 50,000 x 8000 + output 800 x 40000 = 432,000,000.
        try dir.write(
            Fixture.call(
                id: "m1", at: "2026-11-10T00:00:00Z", session: "s1", input: 0, output: 0, write: 60_000,
                iterations: [
                    Fixture.iteration(write: 60_000),
                    Fixture.iteration(type: "advisor_message", model: "claude-fable-5-2", input: 50_000, output: 800),
                ]),
            to: "projects/-p/s1.jsonl")
        // Subagents: Sonnet 5.5 output 100 x 10000 = 1,000,000; Fable 5.1 advisor input 10,000 x 10000 = 100,000,000.
        try dir.write(
            Fixture.call(
                id: "a1", at: "2026-11-10T00:30:00Z", session: "s1", model: "claude-sonnet-5-5", input: 0, output: 100,
                iterations: [
                    Fixture.iteration(output: 100),
                    Fixture.iteration(type: "advisor_message", model: "claude-fable-5-1", input: 10_000),
                ]),
            to: "projects/-p/s1/subagents/agent-a.jsonl")
        let report = try report(of: dir)
        #expect(report.bucketCosts[.sessionStartAndCompaction] == 480_000_000)
        #expect(report.bucketCosts[.normalWork] == 432_000_000)
        #expect(report.bucketCosts[.subagents] == 101_000_000)
        #expect(report.totalCost == 1_013_000_000)
        #expect(report.advisor == AdvisorTotals(calls: 2, inputTokens: 60_000, outputTokens: 800, cost: 532_000_000))
        #expect(report.unpricedModels.isEmpty)
    }

    @Test("only the iteration that rebuilt counts as rebuild tokens and goes to the cause")
    func rebuildIterationOnly() throws {
        let dir = try TempDir()
        try dir.write(
            // normal: write 100 x 8000 = 800,000
            Fixture.call(id: "m0", at: "2026-11-10T00:00:00Z", session: "s1", input: 0, output: 0, write: 100)
                // two hours later the first iteration rebuilds (60,000 x 8000 = 480,000,000, short break) and the
                // second reads it back (300 x 8000 + 70,000 x 200 = 16,400,000, normal work)
                + Fixture.call(
                    id: "m1", at: "2026-11-10T02:00:00Z", session: "s1", input: 0, output: 0, read: 70_000,
                    write: 60_300,
                    iterations: [Fixture.iteration(write: 60_000), Fixture.iteration(read: 70_000, write: 300)]),
            to: "projects/-p/s1.jsonl")
        let report = try report(of: dir)
        #expect(report.rebuildCount == 1)
        #expect(report.rebuildTokens == 60_000)
        #expect(report.shortBreak == BreakTotals(count: 1, tokens: 60_000, cost: 480_000_000))
        #expect(report.bucketCosts[.normalWork] == 800_000 + 16_400_000)
        #expect(report.reducibleCost == 480_000_000 - 60_000 * 200)
        #expect(report.rebuilds.first?.cacheWriteTokens == 60_000)
    }

    @Test("a call copied into a resumed session is the context for that session's next call")
    func copiedCallGivesContext() throws {
        let dir = try TempDir()
        let original = Fixture.call(
            id: "m1", at: "2026-11-10T00:00:00Z", session: "s1", input: 0, output: 0, write: 60_000)
        try dir.write(original, to: "projects/-p/s1.jsonl")
        try dir.write(
            original
                + Fixture.call(id: "m2", at: "2026-11-10T02:00:00Z", session: "s2", input: 0, output: 0, write: 60_000),
            to: "projects/-p/s2.jsonl")
        let report = try report(of: dir)
        #expect(report.calls == 2)
        #expect(report.mainRebuildCounts == [.sessionStart: 1, .expiredShortBreak: 1])
    }
}
