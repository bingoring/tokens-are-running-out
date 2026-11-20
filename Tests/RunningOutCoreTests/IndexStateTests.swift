import Foundation
import Testing

@testable import RunningOutCore

/// R-1: what the index reports to the app after resets and interrupted scans.
@Suite("Index state")
struct IndexStateTests {
    private func indexer(_ dir: TempDir) throws -> Indexer {
        try Indexer(
            root: dir.url.appendingPathComponent("projects"),
            databaseURL: dir.url.appendingPathComponent("index.sqlite"))
    }

    // LOW: a file emptied in place dropped its calls, but nothing told the app to redraw.
    @Test("a file truncated to nothing counts as a reset")
    func truncationReported() throws {
        let dir = try TempDir()
        let file = try dir.write(Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z"), to: "projects/-p/s1.jsonl")
        let indexer = try indexer(dir)
        try indexer.indexAll()

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.close()
        let summary = try indexer.update(paths: [file])

        #expect(summary.filesReset == 1)
        #expect(try indexer.stats(from: 0, to: 4_000_000_000).calls == 0)
    }

    // LOW: quitting during the first index made the next start look like a routine catch-up.
    @Test("a first index that never finished is still the first index")
    func interruptedFirstIndex() throws {
        let dir = try TempDir()
        try dir.write(Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z"), to: "projects/-p/s1.jsonl")
        do {
            let first = try indexer(dir)
            try first.indexAll()
        }
        do {
            // As if the app quit before the scan finished: files are known, but no full scan completed.
            let raw = try SQLiteDatabase(path: dir.url.appendingPathComponent("index.sqlite").path)
            try raw.execute("DELETE FROM meta WHERE key = 'last_full_index_at'")
        }
        try dir.write(Fixture.call(id: "m2", at: "2026-11-10T00:00:00Z"), to: "projects/-p/s2.jsonl")

        let restarted = try indexer(dir)
        var seen: [Bool] = []
        try restarted.indexAll { seen.append($0.isInitial) }
        #expect(!seen.isEmpty && seen.allSatisfy { $0 })

        var afterwards: [Bool] = []
        try restarted.indexAll { afterwards.append($0.isInitial) }
        #expect(!afterwards.contains(true))
    }
}
