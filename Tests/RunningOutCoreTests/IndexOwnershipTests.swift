import Foundation
import Testing

@testable import RunningOutCore

/// R-1: opening an index never harms a file this app did not make, and the app's own index can start over.
@Suite("Index ownership")
struct IndexOwnershipTests {
    private func call(_ id: String) -> String { Fixture.call(id: id, at: "2026-11-10T00:00:00Z") }

    private func calls(_ indexer: Indexer) throws -> Int { try indexer.stats(from: 0, to: 4_000_000_000).calls }

    private func indexer(_ dir: TempDir, _ opening: IndexOpening = .refuseUnknown) throws -> Indexer {
        try Indexer(
            root: dir.url.appendingPathComponent("projects"), databaseURL: database(dir), opening: opening,
            home: dir.url.appendingPathComponent("home"))
    }

    private func database(_ dir: TempDir) -> URL { dir.url.appendingPathComponent("index.sqlite") }

    private func exists(_ url: URL, suffix: String = "") -> Bool {
        FileManager.default.fileExists(atPath: url.path + suffix)
    }

    /// Bytes 18 and 19 of an SQLite header are 2 in WAL mode and 1 with a rollback journal.
    private func header(_ url: URL) throws -> (journalVersions: [UInt8], applicationID: UInt32) {
        let data = try Data(contentsOf: url).prefix(100)
        let id = data[68..<72].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return ([data[18], data[19]], id)
    }

    // MEDIUM (security): a mistyped --db deleted a file that was not an index.
    @Test("a file that is not SQLite is left untouched")
    func notSQLiteLeftAlone() throws {
        let dir = try TempDir()
        let text = String(repeating: "my notes ", count: 400)
        try dir.write(text, to: "index.sqlite")

        #expect(throws: IndexOpenError.self) { try indexer(dir) }

        #expect(try String(contentsOf: database(dir), encoding: .utf8) == text)
        #expect(!exists(database(dir), suffix: "-wal"))
        #expect(!exists(database(dir), suffix: "-shm"))
    }

    // MEDIUM (security): another app's database lost its tables to the schema rebuild.
    @Test("another app's SQLite database keeps its tables and journal mode", arguments: [Int32(0), Int32(1234)])
    func foreignDatabaseLeftAlone(applicationID: Int32) throws {
        let dir = try TempDir()
        do {
            let foreign = try SQLiteDatabase(path: database(dir).path)
            try foreign.execute(
                "PRAGMA application_id = \(applicationID); CREATE TABLE notes(text TEXT); INSERT INTO notes VALUES('keep');"
            )
        }
        let before = try Data(contentsOf: database(dir))

        #expect(throws: IndexOpenError.self) { try indexer(dir) }

        #expect(try Data(contentsOf: database(dir)) == before)
        #expect(try header(database(dir)).journalVersions == [1, 1])
        #expect(!exists(database(dir), suffix: "-wal"))
    }

    @Test("the app's own index replaces a file it cannot use")
    func ownIndexReplacesUnusable() throws {
        let dir = try TempDir()
        try dir.write(call("m1"), to: "projects/-p/s1.jsonl")
        try dir.write(String(repeating: "not a database ", count: 400), to: "index.sqlite")

        let indexer = try indexer(dir, .replaceUnusable)
        try indexer.indexAll()

        #expect(try calls(indexer) == 1)
    }

    @Test("a new index is marked as this app's")
    func newIndexMarked() throws {
        let dir = try TempDir()
        _ = try indexer(dir)

        #expect(try header(database(dir)).applicationID == UInt32(bitPattern: Indexer.applicationID))
    }

    @Test("an index made before the marker is kept and marked")
    func unmarkedOwnIndexKept() throws {
        let dir = try TempDir()
        try dir.write(call("m1"), to: "projects/-p/s1.jsonl")
        do {
            let first = try indexer(dir)
            try first.indexAll()
        }
        do {
            let raw = try SQLiteDatabase(path: database(dir).path)
            try raw.execute("PRAGMA application_id = 0")
        }

        let reopened = try indexer(dir)

        #expect(try calls(reopened) == 1)
        #expect(try header(database(dir)).applicationID == UInt32(bitPattern: Indexer.applicationID))
    }

    // MEDIUM (concurrency): damage found while running came back after every retry.
    @Test("starting over discards an index that still opens")
    func startOverDiscards() throws {
        let dir = try TempDir()
        try dir.write(call("m1"), to: "projects/-p/s1.jsonl")
        do {
            let first = try indexer(dir)
            try first.indexAll()
        }

        let fresh = try indexer(dir, .startOver)

        #expect(try calls(fresh) == 0)
        try fresh.indexAll()
        #expect(try calls(fresh) == 1)
    }

    // MEDIUM (security): the read-only rule compared spellings, so case and links got around it.
    @Test("an index inside ~/.claude or the root is refused whatever the spelling, and nothing is created")
    func locationGuard() throws {
        let dir = try TempDir()
        let home = dir.url.appendingPathComponent("home")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
        let root = home.appendingPathComponent(".claude/projects")
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("link"), withDestinationURL: home.appendingPathComponent(".claude"))
        let viaVar = URL(fileURLWithPath: dir.url.path.replacingOccurrences(of: "/private/var/", with: "/var/"))
        let viaPrivate = URL(fileURLWithPath: dir.url.resolvingSymlinksInPath().path)

        let refused = [
            home.appendingPathComponent(".claude/index.sqlite"),
            home.appendingPathComponent(".CLAUDE/index.sqlite"),
            home.appendingPathComponent("link/index.sqlite"),
            home.appendingPathComponent("link/new/folder/index.sqlite"),
        ]
        for database in refused {
            #expect(throws: IndexOpenError.self) { try IndexLocation.check(database: database, root: root, home: home) }
        }
        let otherRoot = viaVar.appendingPathComponent("transcripts")
        #expect(throws: IndexOpenError.self) {
            try IndexLocation.check(
                database: viaPrivate.appendingPathComponent("transcripts/index.sqlite"), root: otherRoot, home: home)
        }
        try IndexLocation.check(database: dir.url.appendingPathComponent("index.sqlite"), root: root, home: home)

        #expect(throws: IndexOpenError.self) {
            try Indexer(root: root, databaseURL: home.appendingPathComponent("link/x/index.sqlite"), home: home)
        }
        #expect(!exists(home.appendingPathComponent(".claude/x")))
    }

    @Test("index files are private to the user")
    func privatePermissions() throws {
        let dir = try TempDir()
        let database = dir.url.appendingPathComponent("folder/index.sqlite")
        _ = try Indexer(
            root: dir.url.appendingPathComponent("projects"), databaseURL: database,
            home: dir.url.appendingPathComponent("home"))

        let manager = FileManager.default
        let folder = try manager.attributesOfItem(atPath: database.deletingLastPathComponent().path)
        let file = try manager.attributesOfItem(atPath: database.path)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
        #expect((file[.posixPermissions] as? Int) == 0o600)
    }
}
