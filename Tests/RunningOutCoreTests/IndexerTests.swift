import Foundation
import Testing

@testable import RunningOutCore

@Suite("Indexer")
struct IndexerTests {
    // 2026-11-10T00:00:00Z, derived independently with Python.
    private let nov10: Double = 1_794_268_800

    private func makeIndexer(_ dir: TempDir) throws -> Indexer {
        try Indexer(
            root: dir.url.appendingPathComponent("projects"),
            databaseURL: dir.url.appendingPathComponent("index.sqlite"))
    }

    private func everything(_ indexer: Indexer) throws -> UsageTotals {
        try indexer.stats(from: 0, to: 4_000_000_000)
    }

    // MARK: - Counting each call once

    @Test("lines repeated for each content block count as one call")
    func duplicateLinesInOneFile() throws {
        let dir = try TempDir()
        let line = Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1", output: 7, write: 100)
        try dir.write(line + line + line, to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)

        try indexer.indexAll()

        let totals = try everything(indexer)
        #expect(totals.calls == 1)
        #expect(totals.outputTokens == 7)
        #expect(totals.cacheWriteTokens == 100)
    }

    @Test("a call copied into a resumed session is counted once")
    func copiedCallCountedOnce() throws {
        let dir = try TempDir()
        let original = Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1", output: 5)
        try dir.write(original, to: "projects/-p/s1.jsonl")
        try dir.write(
            original + Fixture.call(id: "m2", at: "2026-11-10T01:00:00Z", session: "s2"), to: "projects/-p/s2.jsonl")
        let indexer = try makeIndexer(dir)

        try indexer.indexAll()

        #expect(try everything(indexer).calls == 2)
    }

    @Test("the file named after the line's sessionId owns a copied call, even if created later")
    func ownerBySessionID() throws {
        let dir = try TempDir()
        let copied = Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1")
        let originalFile = try dir.write(copied, to: "projects/-p/s1.jsonl")
        let copyFile = try dir.write(copied, to: "projects/-p/s2.jsonl")
        try dir.setCreationDate(Date(timeIntervalSince1970: 2_000), of: originalFile)
        try dir.setCreationDate(Date(timeIntervalSince1970: 1_000), of: copyFile)
        let indexer = try makeIndexer(dir)

        try indexer.indexAll()

        #expect(try indexer.owner(of: "m1")?.lastPathComponent == "s1.jsonl")
    }

    @Test("when the copy also rewrote the sessionId, the file created first owns the call")
    func ownerByCreationDate() throws {
        let dir = try TempDir()
        let first = try dir.write(
            Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1"), to: "projects/-p/s1.jsonl")
        let second = try dir.write(
            Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s2"), to: "projects/-p/s2.jsonl")
        try dir.setCreationDate(Date(timeIntervalSince1970: 2_000), of: first)
        try dir.setCreationDate(Date(timeIntervalSince1970: 1_000), of: second)
        let indexer = try makeIndexer(dir)

        try indexer.indexAll()

        #expect(try indexer.owner(of: "m1")?.lastPathComponent == "s2.jsonl")
    }

    @Test("subagent copies are owned by the agent file created first")
    func subagentOwner() throws {
        let dir = try TempDir()
        let line = Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1", ttl: "5m")
        let a = try dir.write(line, to: "projects/-p/s1/subagents/agent-a.jsonl")
        let b = try dir.write(line, to: "projects/-p/s1/subagents/agent-b.jsonl")
        try dir.setCreationDate(Date(timeIntervalSince1970: 2_000), of: a)
        try dir.setCreationDate(Date(timeIntervalSince1970: 1_000), of: b)
        let indexer = try makeIndexer(dir)

        try indexer.indexAll()

        #expect(try indexer.owner(of: "m1")?.lastPathComponent == "agent-b.jsonl")
    }

    // MARK: - Incremental reading

    @Test("lines appended later are added without reading the file again")
    func appendIsIncremental() throws {
        let dir = try TempDir()
        let file = try dir.write(
            Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1"), to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()

        try dir.append(Fixture.call(id: "m2", at: "2026-11-10T00:01:00Z", session: "s1"), to: file)
        try indexer.update(paths: [file])

        #expect(try everything(indexer).calls == 2)
        #expect(try indexer.timeline(of: file).map(\.seq) == [0, 1])
    }

    @Test("a line still being written is picked up once its newline arrives")
    func partialLine() throws {
        let dir = try TempDir()
        let second = Fixture.call(id: "m2", at: "2026-11-10T00:01:00Z", session: "s1")
        let half = second.index(second.startIndex, offsetBy: 40)
        let file = try dir.write(
            Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1") + String(second[..<half]),
            to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)

        try indexer.indexAll()
        #expect(try everything(indexer).calls == 1)

        try dir.append(String(second[half...]), to: file)
        try indexer.update(paths: [file])
        #expect(try everything(indexer).calls == 2)
    }

    @Test("reading in several steps gives the same index as reading once")
    func stepwiseEqualsOnce() throws {
        let lines = [
            Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1", write: 100),
            Fixture.compact(at: "2026-11-10T00:05:00Z"),
            Fixture.call(id: "m2", at: "2026-11-10T00:06:00Z", session: "s1", read: 50),
            Fixture.call(id: "m2", at: "2026-11-10T00:06:00Z", session: "s1", read: 50),
            Fixture.call(id: "m3", at: "2026-11-10T02:00:00Z", session: "s1", write: 70),
        ]
        let onceDir = try TempDir()
        let onceFile = try onceDir.write(lines.joined(), to: "projects/-p/s1.jsonl")
        let once = try makeIndexer(onceDir)
        try once.indexAll()

        let stepDir = try TempDir()
        let stepFile = try stepDir.write(lines[0], to: "projects/-p/s1.jsonl")
        let steps = try makeIndexer(stepDir)
        try steps.indexAll()
        for line in lines.dropFirst() {
            try stepDir.append(line, to: stepFile)
            try steps.update(paths: [stepFile])
        }

        #expect(try everything(steps) == everything(once))
        #expect(try steps.timeline(of: stepFile) == once.timeline(of: onceFile))
    }

    // MARK: - Files that change underneath

    @Test("a truncated file is read again from the start")
    func truncatedFile() throws {
        let dir = try TempDir()
        let file = try dir.write(
            Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1")
                + Fixture.call(id: "m2", at: "2026-11-10T00:01:00Z", session: "s1"),
            to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(Fixture.call(id: "m3", at: "2026-11-10T00:02:00Z", session: "s1").utf8))
        try handle.close()
        try indexer.update(paths: [file])

        #expect(try everything(indexer).calls == 1)
        #expect(try indexer.owner(of: "m3") != nil)
        #expect(try indexer.owner(of: "m1") == nil)
    }

    @Test("a file replaced by a new one is read again from the start")
    func replacedFile() throws {
        let dir = try TempDir()
        let file = try dir.write(
            Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1"), to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()

        let replacement = try dir.write(
            Fixture.call(id: "m9", at: "2026-11-10T00:00:00Z", session: "s1")
                + Fixture.call(id: "m8", at: "2026-11-10T00:01:00Z", session: "s1"),
            to: "replacement.jsonl")
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        try indexer.update(paths: [file])

        #expect(try everything(indexer).calls == 2)
        #expect(try indexer.owner(of: "m1") == nil)
    }

    @Test("when the owning file disappears, a remaining copy takes over")
    func removedOwner() throws {
        let dir = try TempDir()
        let line = Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1")
        let original = try dir.write(line, to: "projects/-p/s1.jsonl")
        try dir.write(line, to: "projects/-p/s2.jsonl")
        let onlyHere = try dir.write(
            Fixture.call(id: "m5", at: "2026-11-10T00:00:00Z", session: "s1"), to: "projects/-p/s3.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()

        try FileManager.default.removeItem(at: original)
        try FileManager.default.removeItem(at: onlyHere)
        try indexer.update(paths: [original, onlyHere])

        #expect(try indexer.owner(of: "m1")?.lastPathComponent == "s2.jsonl")
        #expect(try indexer.owner(of: "m5") == nil)
        #expect(try everything(indexer).calls == 1)
    }

    @Test("a full scan notices files that were deleted while the app was closed")
    func fullScanRemovesVanishedFiles() throws {
        let dir = try TempDir()
        let file = try dir.write(
            Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1"), to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()

        try FileManager.default.removeItem(at: file)
        try indexer.indexAll()

        #expect(try everything(indexer).calls == 0)
    }

    // MARK: - Timeline, titles, health

    @Test("calls and compaction marks keep their order in the file")
    func timelineOrder() throws {
        let dir = try TempDir()
        let file = try dir.write(
            Fixture.user()
                + Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1")
                + Fixture.compact(at: "2026-11-10T00:05:00Z")
                + Fixture.call(id: "m2", at: "2026-11-10T00:06:00Z", session: "s1"),
            to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)

        try indexer.indexAll()

        let kinds = try indexer.timeline(of: file).map { event -> String in
            switch event.kind {
            case .call(let call, _): return call.messageID
            case .compaction: return "compact"
            }
        }
        #expect(kinds == ["m1", "compact", "m2"])
    }

    @Test("copied calls appear in the copy's timeline but are marked as not owned")
    func copiedCallInTimeline() throws {
        let dir = try TempDir()
        let line = Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1")
        try dir.write(line, to: "projects/-p/s1.jsonl")
        let copy = try dir.write(
            line + Fixture.call(id: "m2", at: "2026-11-10T03:00:00Z", session: "s2"), to: "projects/-p/s2.jsonl")
        let indexer = try makeIndexer(dir)

        try indexer.indexAll()

        let owned = try indexer.timeline(of: copy).map { event -> Bool in
            if case .call(_, let owned) = event.kind { return owned }
            return false
        }
        #expect(owned == [false, true])
    }

    @Test("the title read last wins")
    func latestTitle() throws {
        let dir = try TempDir()
        let file = try dir.write(Fixture.title("first", session: "s1"), to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()

        try dir.append(Fixture.title("second", session: "s1"), to: file)
        try indexer.update(paths: [file])

        #expect(try indexer.title(of: "s1") == "second")
    }

    @Test("broken candidate lines are counted and do not stop indexing")
    func parseFailures() throws {
        let dir = try TempDir()
        try dir.write(
            #"{"type":"assistant","usage": {"# + "\n"
                + Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1"),
            to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)

        let summary = try indexer.indexAll()

        #expect(summary.parseFailures == 1)
        #expect(try everything(indexer).calls == 1)
    }

    // MARK: - Stats window

    @Test("the stats window includes its start and excludes its end")
    func statsWindow() throws {
        let dir = try TempDir()
        try dir.write(
            Fixture.call(id: "before", at: "2026-11-09T23:59:59Z", session: "s1", output: 1)
                + Fixture.call(id: "start", at: "2026-11-10T00:00:00Z", session: "s1", output: 10)
                + Fixture.call(id: "end", at: "2026-11-11T00:00:00Z", session: "s1", output: 100),
            to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()

        let totals = try indexer.stats(from: nov10, to: nov10 + 86_400)

        #expect(totals.calls == 1)
        #expect(totals.outputTokens == 10)
    }

    @Test("an index survives being reopened")
    func reopen() throws {
        let dir = try TempDir()
        let file = try dir.write(
            Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1"), to: "projects/-p/s1.jsonl")
        do {
            let indexer = try makeIndexer(dir)
            try indexer.indexAll()
        }
        try dir.append(Fixture.call(id: "m2", at: "2026-11-10T00:01:00Z", session: "s1"), to: file)

        let reopened = try makeIndexer(dir)
        try reopened.update(paths: [file])

        #expect(try everything(reopened).calls == 2)
        #expect(try reopened.timeline(of: file).map(\.seq) == [0, 1])
    }

    // MARK: - The final usage of a message

    private func calls(_ indexer: Indexer, in file: URL) throws -> [CallRecord] {
        try indexer.timeline(of: file).compactMap { event in
            if case .call(let call, _) = event.kind { return call }
            return nil
        }
    }

    @Test("a message's usage comes from its last line and its place in the file from its first")
    func lastLineUsage() throws {
        let dir = try TempDir()
        let file = try dir.write(
            Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1", output: 10)
                + Fixture.call(id: "m2", at: "2026-11-10T00:00:05Z", session: "s1", output: 1)
                + Fixture.call(
                    id: "m1", at: "2026-11-10T00:00:09Z", session: "s1", output: 500,
                    iterations: [
                        Fixture.iteration(input: 2, output: 500),
                        Fixture.iteration(type: "advisor_message", model: "claude-fable-5-2", input: 9_000, output: 70),
                    ]),
            to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)

        try indexer.indexAll()

        #expect(try everything(indexer) == UsageTotals(calls: 2, inputTokens: 4, outputTokens: 501))
        let found = try calls(indexer, in: file)
        #expect(found.map(\.messageID) == ["m1", "m2"])
        #expect(found.first?.timestamp == nov10)
        #expect(found.first?.outputTokens == 500)
        #expect(found.first?.iterations.count == 2)
    }

    @Test("a message's last line that arrives in a later scan updates the call")
    func lastLineInLaterScan() throws {
        let dir = try TempDir()
        let file = try dir.write(
            Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1", output: 10), to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()

        try dir.append(Fixture.call(id: "m1", at: "2026-11-10T00:00:09Z", session: "s1", output: 500), to: file)
        try indexer.update(paths: [file])

        #expect(try everything(indexer) == UsageTotals(calls: 1, inputTokens: 2, outputTokens: 500))
        #expect(try calls(indexer, in: file).first?.outputTokens == 500)
    }

    // MARK: - Health, last call, progress

    private func assistantLine(_ id: String, at timestamp: String, usageKey: String = "usage") -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","sessionId":"s1","message":{"id":"\#(id)","model":"claude-opus-5-5","\#(usageKey)":{"output_tokens":1}}}"#
            + "\n"
    }

    @Test("assistant lines that stop being calls raise a format change: renamed usage or a missing id")
    func formatChangeFromAssistantLines() throws {
        for broken in ["renamed", "noID"] {
            let dir = try TempDir()
            var text = ""
            for n in 0..<60 {
                let at = "2026-11-10T00:\(String(format: "%02d", n)):00Z"
                text +=
                    broken == "renamed"
                    ? assistantLine("m\(n)", at: at, usageKey: "usage_v2")
                    : #"{"type":"assistant","timestamp":"\#(at)","message":{"model":"claude-opus-5-5","usage":{"output_tokens":1}}}"#
                        + "\n"
            }
            try dir.write(text, to: "projects/-p/s1.jsonl")
            let indexer = try makeIndexer(dir)
            try indexer.indexAll()
            let health = try indexer.health(now: nov10 + 86_400)
            #expect(health.kind == .unreadableLines(share: 1), "\(broken)")
            #expect(health.assistantLines == 60)
        }
    }

    @Test("synthetic messages among normal calls do not raise a format change")
    func syntheticIsHealthy() throws {
        let dir = try TempDir()
        var text = ""
        for n in 0..<99 { text += assistantLine("m\(n)", at: "2026-11-10T01:\(String(format: "%02d", n % 60)):00Z") }
        text +=
            #"{"type":"assistant","timestamp":"2026-11-10T02:00:00Z","message":{"id":"x","model":"<synthetic>","usage":{"output_tokens":0}}}"#
            + "\n"
        try dir.write(text, to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()
        let health = try indexer.health(now: nov10 + 86_400)
        #expect(health.kind == .none)
        #expect(health.assistantWithoutCall == 0)
    }

    @Test("assistant lines older than seven days do not count, so old history never raises the banner")
    func oldLinesIgnored() throws {
        let dir = try TempDir()
        var text = ""
        for n in 0..<60 {
            text += assistantLine("m\(n)", at: "2026-10-01T00:\(String(format: "%02d", n)):00Z", usageKey: "u")
        }
        try dir.write(text, to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()
        #expect(try indexer.health(now: nov10).kind == .none)
    }

    @Test("main transcripts that grow by 200 lines with no calls after the first index raise a format change")
    func formatChangeFromNoCalls() throws {
        let dir = try TempDir()
        let file = try dir.write(
            Fixture.call(id: "m0", at: "2026-11-10T00:00:00Z", session: "s1"), to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()
        // The first index read old lines; only what is appended afterwards counts for this rule.
        #expect(try indexer.health(now: Date().timeIntervalSince1970).kind == .none)
        var appended = ""
        for n in 0..<200 { appended += #"{"type":"reply","id":"r\#(n)","tokens":{"out":1}}"# + "\n" }
        try dir.append(appended, to: file)
        try indexer.update(paths: [file])
        #expect(try indexer.health(now: Date().timeIntervalSince1970).kind == .noCalls)
    }

    @Test("the first index of 200 lines with no calls is not a format change")
    func firstIndexWithoutCallsIsHealthy() throws {
        let dir = try TempDir()
        var text = ""
        for n in 0..<200 { text += #"{"type":"user","id":"u\#(n)"}"# + "\n" }
        try dir.write(text, to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()
        #expect(try indexer.health(now: Date().timeIntervalSince1970).kind == .none)
    }

    @Test("a session's last call carries its final usage, its context size and an inherited TTL")
    func lastCallOfSession() throws {
        let dir = try TempDir()
        try dir.write(
            Fixture.title("Refactor parser", session: "s1")
                // The earlier call's five-minute TTL, not the one-hour default, carries over to m2.
                + Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1", write: 80_000, ttl: "5m")
                + Fixture.call(id: "m2", at: "2026-11-10T00:10:00Z", session: "s1", output: 5, read: 80_000)
                + Fixture.call(
                    id: "m2", at: "2026-11-10T00:10:00Z", session: "s1", input: 3, output: 900, read: 80_000,
                    write: 2_000, ttl: "none"),
            to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()
        let last = try #require(try indexer.lastCall(ofSession: "s1"))
        #expect(last.timestamp == nov10 + 600)
        #expect(last.ttl == .fiveMinutes)
        #expect(last.contextTokens == 3 + 80_000 + 2_000)
        #expect(last.title == "Refactor parser")
        #expect(try indexer.lastCall(ofSession: "missing") == nil)
        #expect(try indexer.mainSessions(withCallsSince: nov10 + 300) == ["s1"])
        #expect(try indexer.mainSessions(withCallsSince: nov10 + 700).isEmpty)
    }

    @Test("indexing reports progress in bytes, and only the first index is initial")
    func progress() throws {
        let dir = try TempDir()
        let file = try dir.write(
            Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1"), to: "projects/-p/s1.jsonl")
        try dir.write(Fixture.call(id: "m2", at: "2026-11-10T00:00:00Z", session: "s2"), to: "projects/-p/s2.jsonl")
        let indexer = try makeIndexer(dir)
        var seen: [IndexProgress] = []
        try indexer.indexAll { seen.append($0) }
        let size = Int64(try Data(contentsOf: file).count)
        #expect(seen.last?.bytesRead == seen.last?.bytesTotal)
        #expect(seen.last?.bytesTotal ?? 0 >= size)
        #expect(seen.allSatisfy { $0.isInitial })
        seen = []
        try indexer.indexAll { seen.append($0) }
        #expect(seen.allSatisfy { !$0.isInitial })
        #expect(seen.last?.bytesTotal == 0)
    }

    private func lines(_ count: Int, broken: Int, synthetic: Int = 0) -> String {
        var text = ""
        for n in 0..<count {
            let at = "2026-11-10T\(String(format: "%02d", n / 60)):\(String(format: "%02d", n % 60)):00Z"
            text += assistantLine("m\(n)", at: at, usageKey: n < broken ? "usage_v2" : "usage")
        }
        for n in 0..<synthetic {
            text +=
                #"{"type":"assistant","timestamp":"2026-11-10T09:00:00Z","message":{"id":"x\#(n)","model":"<synthetic>","usage":{"output_tokens":0}}}"#
                + "\n"
        }
        return text
    }

    private func health(of text: String) throws -> IndexHealth {
        let dir = try TempDir()
        try dir.write(text, to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()
        return try indexer.health(now: nov10 + 86_400)
    }

    @Test("the unreadable-lines rule needs 50 assistant lines and more than 5% of them broken")
    func unreadableBoundaries() throws {
        #expect(try health(of: lines(49, broken: 49)).kind == .none)
        #expect(try health(of: lines(50, broken: 50)).kind == .unreadableLines(share: 1))
        #expect(try health(of: lines(100, broken: 5)).kind == .none)
        #expect(try health(of: lines(100, broken: 6)).kind == .unreadableLines(share: 0.06))
    }

    @Test("synthetic messages, even many of them, are not a format change")
    func manySynthetic() throws {
        let found = try health(of: lines(140, broken: 0, synthetic: 10))
        #expect(found.kind == .none)
        #expect(found.assistantWithoutCall == 0)
    }

    @Test("the no-calls rule needs 200 appended lines on one day")
    func noCallsBoundary() throws {
        for (count, expected) in [(199, IndexHealth.Kind.none), (200, .noCalls)] {
            let dir = try TempDir()
            let file = try dir.write(
                Fixture.call(id: "m0", at: "2026-11-10T00:00:00Z", session: "s1"), to: "projects/-p/s1.jsonl")
            let indexer = try makeIndexer(dir)
            try indexer.indexAll()
            var appended = ""
            for n in 0..<count { appended += #"{"type":"reply","id":"r\#(n)"}"# + "\n" }
            try dir.append(appended, to: file)
            try indexer.update(paths: [file])
            #expect(try indexer.health(now: Date().timeIntervalSince1970).kind == expected, "\(count)")
        }
    }

    @Test("a call earlier in the week does not hide a day of appended lines without calls")
    func noCallsPerDay() throws {
        let dir = try TempDir()
        let file = try dir.write(
            Fixture.call(id: "m0", at: "2026-11-10T00:00:00Z", session: "s1"), to: "projects/-p/s1.jsonl")
        var now = nov10
        let indexer = try Indexer(
            root: dir.url.appendingPathComponent("projects"),
            databaseURL: dir.url.appendingPathComponent("index.sqlite"), clock: { now })
        try indexer.indexAll()
        // Calls appended on one day, then three days later a day of lines without calls.
        try dir.append(Fixture.call(id: "m1", at: "2026-11-10T01:00:00Z", session: "s1"), to: file)
        try indexer.update(paths: [file])
        now += 3 * 86_400
        var appended = ""
        for n in 0..<200 { appended += #"{"type":"reply","id":"r\#(n)"}"# + "\n" }
        try dir.append(appended, to: file)
        try indexer.update(paths: [file])
        #expect(try indexer.health(now: now).kind == .noCalls)
    }
}
