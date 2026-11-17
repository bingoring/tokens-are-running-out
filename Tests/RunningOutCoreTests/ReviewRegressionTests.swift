import Foundation
import Testing

@testable import RunningOutCore

/// Regressions for the independent review of stage 2-1 (2026-11-17).
@Suite("Review regressions")
struct ReviewRegressionTests {
    private let nov10: Double = 1_794_268_800  // 2026-11-10T00:00:00Z

    private func makeIndexer(_ dir: TempDir) throws -> Indexer {
        try Indexer(
            root: dir.url.appendingPathComponent("projects"),
            databaseURL: dir.url.appendingPathComponent("index.sqlite"))
    }

    private func all(_ indexer: Indexer) throws -> UsageTotals {
        try indexer.stats(from: 0, to: 4_000_000_000)
    }

    // CRITICAL: a cached SELECT left mid-step kept a read snapshot open forever.
    @Test("a long-lived indexer sees what another connection wrote")
    func noStaleSnapshot() throws {
        let dir = try TempDir()
        let file = try dir.write(
            Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", session: "s1"), to: "projects/-p/s1.jsonl")
        let longLived = try makeIndexer(dir)
        try longLived.indexAll()
        #expect(try all(longLived).calls == 1)

        let other = try makeIndexer(dir)
        try dir.append(Fixture.call(id: "m2", at: "2026-11-10T00:01:00Z", session: "s1"), to: file)
        try other.update(paths: [file])

        #expect(try all(longLived).calls == 2)
        try dir.append(Fixture.call(id: "m3", at: "2026-11-10T00:02:00Z", session: "s1"), to: file)
        try longLived.update(paths: [file])
        #expect(try all(longLived).calls == 3)
    }

    // HIGH: one bad file stopped the whole scan.
    @Test("an unreadable file is skipped and reported while the rest is indexed")
    func unreadableFileSkipped() throws {
        let dir = try TempDir()
        let locked = try dir.write(Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z"), to: "projects/-p/a.jsonl")
        try dir.write(Fixture.call(id: "m2", at: "2026-11-10T00:00:00Z"), to: "projects/-p/b.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let indexer = try makeIndexer(dir)

        let summary = try indexer.indexAll()

        #expect(summary.skippedFiles.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["a.jsonl"])
        #expect(try all(indexer).calls == 1)
    }

    @Test("a directory whose name ends in .jsonl is not a transcript")
    func directoryNamedLikeTranscript() throws {
        let dir = try TempDir()
        try FileManager.default.createDirectory(
            at: dir.url.appendingPathComponent("projects/-p/weird.jsonl"), withIntermediateDirectories: true)
        try dir.write(Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z"), to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)

        let summary = try indexer.indexAll()

        #expect(summary.skippedFiles.isEmpty)
        #expect(try all(indexer).calls == 1)
    }

    // MEDIUM: an unreadable folder looked like a deleted one.
    @Test("files in a folder that becomes unreadable keep their calls")
    func unreadableFolderKeepsCalls() throws {
        let dir = try TempDir()
        try dir.write(Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z"), to: "projects/-p/s1.jsonl")
        try dir.write(Fixture.call(id: "m2", at: "2026-11-10T00:00:00Z"), to: "projects/-q/s2.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()

        let folder = dir.url.appendingPathComponent("projects/-p")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let summary = try indexer.indexAll()

        #expect(summary.filesRemoved == 0)
        #expect(try all(indexer).calls == 2)
    }

    // MEDIUM: the call row took the values of whichever copy was read first.
    @Test("a copied call is counted with its owner's values, whatever the reading order")
    func ownerValuesWin() throws {
        let dir = try TempDir()
        let original = try dir.write(
            Fixture.call(id: "m1", at: "2026-11-10T23:59:59Z", session: "s1", output: 100), to: "projects/-p/s1.jsonl")
        let copy = try dir.write(
            Fixture.call(id: "m1", at: "2026-11-11T00:00:05Z", session: "s1", output: 999), to: "projects/-p/s2.jsonl")
        // The copy is newer, so a full scan reads it first.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: original.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: copy.path)
        let indexer = try makeIndexer(dir)

        try indexer.indexAll()

        let nov10Day = try indexer.stats(from: nov10, to: nov10 + 86_400)
        #expect(nov10Day.calls == 1)
        #expect(nov10Day.outputTokens == 100)
        #expect(try indexer.usageMismatchCount() == 1)
        let copyTimes = try indexer.timeline(of: copy).compactMap { event -> Double? in
            if case .call(let call, _) = event.kind { return call.timestamp }
            return nil
        }
        #expect(copyTimes == [nov10 + 86_405])  // each file keeps its own line's values for context
    }

    // MEDIUM: titles survived truncation and deletion.
    @Test("a file rewritten from scratch replaces its old title")
    func titleAfterTruncation() throws {
        let dir = try TempDir()
        let file = try dir.write(
            Fixture.call(id: "m0", at: "2026-11-10T00:00:00Z", session: "s1") + Fixture.title("old", session: "s1"),
            to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(Fixture.title("new", session: "s1").utf8))
        try handle.close()
        try indexer.update(paths: [file])

        #expect(try indexer.title(of: "s1") == "new")
    }

    @Test("a deleted file's title is forgotten")
    func titleAfterDeletion() throws {
        let dir = try TempDir()
        let file = try dir.write(Fixture.title("gone", session: "s1"), to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()

        try FileManager.default.removeItem(at: file)
        try indexer.update(paths: [file])

        #expect(try indexer.title(of: "s1") == nil)
    }

    // LOW: a file rewritten in place (same inode) and not shorter kept stale calls.
    @Test("a file rewritten in place with new content is read again from the start")
    func rewrittenInPlace() throws {
        let dir = try TempDir()
        let file = try dir.write(
            Fixture.call(id: "old1", at: "2026-11-10T00:00:00Z", session: "s1"), to: "projects/-p/s1.jsonl")
        let indexer = try makeIndexer(dir)
        try indexer.indexAll()

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(
            contentsOf: Data(
                (Fixture.call(id: "new1", at: "2026-11-10T01:00:00Z", session: "s1")
                    + Fixture.call(id: "new2", at: "2026-11-10T02:00:00Z", session: "s1")).utf8))
        try handle.close()
        try indexer.update(paths: [file])

        #expect(try indexer.owner(of: "old1") == nil)
        #expect(try indexer.owner(of: "new1") != nil)
        #expect(try all(indexer).calls == 2)
    }

    // MEDIUM: a corrupt index made every start fail.
    @Test("a corrupt index file is rebuilt")
    func corruptIndexRebuilt() throws {
        let dir = try TempDir()
        try dir.write(Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z"), to: "projects/-p/s1.jsonl")
        try dir.write(String(repeating: "not a database ", count: 400), to: "index.sqlite")

        let indexer = try makeIndexer(dir)
        try indexer.indexAll()

        #expect(try all(indexer).calls == 1)
    }

    // NIT: update() accepted hidden files that a full scan then removed.
    @Test("hidden files are not transcripts")
    func hiddenFileIgnored() throws {
        let dir = try TempDir()
        let hidden = try dir.write(Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z"), to: "projects/-p/.s1.jsonl")
        let indexer = try makeIndexer(dir)

        try indexer.update(paths: [hidden])

        #expect(try all(indexer).calls == 0)
    }
}
