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

    // HIGH (deletion re-review): a meta table with a schema_version row was taken for this app's old index.
    @Test(
        "another app's database with its own meta table is left untouched",
        arguments: ["7 value", "4 value", "4 val"])
    func foreignMetaLeftAlone(variant: String) throws {
        let parts = variant.split(separator: " ").map(String.init)
        let dir = try TempDir()
        do {
            let foreign = try SQLiteDatabase(path: database(dir).path)
            try foreign.execute(
                """
                CREATE TABLE meta(key TEXT PRIMARY KEY, \(parts[1]) TEXT);
                INSERT INTO meta VALUES('schema_version', '\(parts[0])');
                CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT); INSERT INTO files(path) VALUES('mine');
                CREATE TABLE calls(id INTEGER PRIMARY KEY); INSERT INTO calls VALUES(1);
                """)
        }
        let before = try Data(contentsOf: database(dir))
        let mode = try FileManager.default.attributesOfItem(atPath: database(dir).path)[.posixPermissions] as? Int

        #expect(throws: IndexOpenError.self) { try indexer(dir) }

        #expect(try Data(contentsOf: database(dir)) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: database(dir).path)[.posixPermissions] as? Int == mode)
        for suffix in ["-wal", "-shm"] { #expect(!exists(database(dir), suffix: suffix)) }
    }

    // HIGH (deletion re-review): the path checked was not the path written.
    @Test("a dangling link or link/.. cannot put the index inside the root")
    func linkTricksRefused() throws {
        let dir = try TempDir()
        let root = dir.url.appendingPathComponent("root")
        let out = dir.url.appendingPathComponent("out")
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("-p/sub"), withIntermediateDirectories: true)
        try manager.createDirectory(at: out, withIntermediateDirectories: true)
        try manager.createSymbolicLink(
            at: out.appendingPathComponent("index.sqlite"),
            withDestinationURL: root.appendingPathComponent("planted.sqlite"))
        try manager.createSymbolicLink(
            at: out.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("-p/sub"))
        let home = dir.url.appendingPathComponent("home")

        let tricks = [
            out.appendingPathComponent("index.sqlite"),
            URL(fileURLWithPath: out.path + "/link/../index.sqlite"),
            URL(fileURLWithPath: out.path + "/link/../new/index.sqlite"),
        ]
        for database in tricks {
            #expect(throws: IndexOpenError.self) { try Indexer(root: root, databaseURL: database, home: home) }
        }
        for planted in ["planted.sqlite", "-p/index.sqlite", "-p/new"] {
            #expect(!exists(root.appendingPathComponent(planted)))
        }
    }

    // MEDIUM (deletion re-review): a new index kept its schema and marker only in the WAL until a checkpoint.
    @Test("a new index is recognizable from its file while it is still open")
    func newIndexRecognizableWhileOpen() throws {
        let dir = try TempDir()
        let open = try indexer(dir)

        #expect(try header(database(dir)).applicationID == UInt32(bitPattern: Indexer.applicationID))
        let probe = try SQLiteDatabase(immutableSnapshotOf: database(dir))
        #expect(try probe.queryRow("SELECT value FROM meta WHERE key = 'schema_version'") { $0.text(0) } == "4")
        #expect(try calls(open) == 0)
    }

    // LOW (deletion re-review): side files left by a database whose main file is gone were overwritten.
    @Test("side files without their database are left untouched")
    func orphanSideFilesLeftAlone() throws {
        let dir = try TempDir()
        try dir.write("someone's wal", to: "index.sqlite-wal")
        try dir.write("someone's journal", to: "index.sqlite-journal")

        #expect(throws: IndexOpenError.self) { try indexer(dir) }

        #expect(try String(contentsOfFile: database(dir).path + "-wal", encoding: .utf8) == "someone's wal")
        #expect(try String(contentsOfFile: database(dir).path + "-journal", encoding: .utf8) == "someone's journal")
        #expect(!exists(database(dir)))
    }

    // LOW (deletion re-review): starting over removed whatever was at the path, a folder included; a pipe hung.
    @Test("a folder, link or pipe at the index path is reported, never removed or waited on")
    func nonFilesNotRemoved() throws {
        let dir = try TempDir()
        try dir.write("keep", to: "index.sqlite/inside.txt")
        #expect(throws: IndexOpenError.self) { try indexer(dir, .startOver) }
        #expect(throws: IndexOpenError.self) { try indexer(dir, .replaceUnusable) }
        #expect(exists(dir.url.appendingPathComponent("index.sqlite/inside.txt")))

        let other = try TempDir()
        #expect(mkfifo(database(other).path, 0o600) == 0)
        #expect(throws: IndexOpenError.self) { try indexer(other) }
        #expect(throws: IndexOpenError.self) { try indexer(other, .replaceUnusable) }
        #expect(exists(database(other)))
    }

    @Test("a damaged index at a path someone chose is reported, not deleted")
    func damagedExternalKept() throws {
        let dir = try TempDir()
        try dir.write(call("m1"), to: "projects/-p/s1.jsonl")
        do {
            let first = try indexer(dir)
            try first.indexAll()
        }
        let handle = try FileHandle(forWritingTo: database(dir))
        try handle.seek(toOffset: 4096)
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 8192))
        try handle.close()
        let before = try Data(contentsOf: database(dir))

        #expect(throws: (any Error).self) {
            let damaged = try indexer(dir)
            try damaged.indexAll()
        }

        #expect(try Data(contentsOf: database(dir)) == before)
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
