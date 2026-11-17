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
}
