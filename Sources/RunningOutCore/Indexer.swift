import Foundation

/// Token totals for calls whose timestamp falls in a window.
public struct UsageTotals: Sendable, Equatable {
    public var calls = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWriteTokens = 0
}

public struct IndexSummary: Sendable, Equatable {
    public var filesScanned = 0
    public var filesRead = 0
    public var filesRemoved = 0
    public var callsAdded = 0
    public var parseFailures = 0

    mutating func add(_ other: IndexSummary) {
        filesScanned += other.filesScanned
        filesRead += other.filesRead
        filesRemoved += other.filesRemoved
        callsAdded += other.callsAdded
        parseFailures += other.parseFailures
    }
}

/// One event in a transcript, in file order.
public struct TimelineEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `owned` is false when the call was copied here and is counted in another file.
        case call(CallRecord, owned: Bool)
        case compaction(timestamp: Double?)
    }

    public var seq: Int
    public var kind: Kind
}

/// Incrementally indexes Claude Code transcripts into SQLite. It only reads the transcripts;
/// the only file it writes is the index database. Use one instance from one thread at a time.
public final class Indexer {
    public let root: URL
    private let db: SQLiteDatabase
    private static let schemaVersion = "1"

    public init(root: URL, databaseURL: URL) throws {
        self.root = TranscriptLocator.canonical(root)
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: databaseURL.path)
        try prepareSchema()
    }

    // MARK: - Indexing

    /// Scans the whole root: reads new and changed files, newest first, and forgets vanished ones.
    @discardableResult
    public func indexAll() throws -> IndexSummary {
        var summary = IndexSummary()
        let refs = try TranscriptLocator.findAll(root: root)
        let present = Set(refs.map(\.url.path))
        for path in try knownPaths() where !present.contains(path) {
            try removeFile(path: path)
            summary.filesRemoved += 1
        }
        let stated = refs.compactMap { ref in FileStat(ref.url).map { (ref, $0) } }
        for (ref, stat) in stated.sorted(by: { $0.1.modified > $1.1.modified }) {
            summary.add(try index(ref, stat))
        }
        return summary
    }

    /// Re-checks the given files or folders, for example the paths FSEvents reported.
    @discardableResult
    public func update(paths: [URL]) throws -> IndexSummary {
        var summary = IndexSummary()
        var handled = Set<String>()
        for path in paths.map(TranscriptLocator.canonical) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                for known in try knownPaths(under: path.path) {
                    try removeFile(path: known)
                    summary.filesRemoved += 1
                }
                continue
            }
            let refs =
                isDirectory.boolValue
                ? try TranscriptLocator.findAll(root: root, under: path)
                : [TranscriptLocator.classify(path, root: root)].compactMap { $0 }
            for ref in refs where handled.insert(ref.url.path).inserted {
                if let stat = FileStat(ref.url) { summary.add(try index(ref, stat)) }
            }
            if isDirectory.boolValue {
                let present = Set(refs.map(\.url.path))
                for known in try knownPaths(under: path.path) where !present.contains(known) {
                    try removeFile(path: known)
                    summary.filesRemoved += 1
                }
            }
        }
        return summary
    }

    private func index(_ ref: TranscriptRef, _ stat: FileStat) throws -> IndexSummary {
        try db.transaction {
            var summary = IndexSummary(filesScanned: 1)
            var file = try fileRow(path: ref.url.path) ?? insertFile(ref, stat)
            if file.inode != stat.inode || stat.size < file.offset {
                try resetFile(file)  // R7: replaced or truncated
                file.offset = 0
                file.nextSeq = 0
            }
            file.inode = stat.inode
            file.birthtime = stat.birthtime
            try db.statement("UPDATE files SET inode = ?, birthtime = ? WHERE id = ?")
                .bind(.int(Int64(bitPattern: file.inode)), .double(file.birthtime), .int(file.id)).run()
            guard stat.size > file.offset else { return summary }

            summary.filesRead = 1
            var seq = file.nextSeq
            var lines = 0
            var candidates = 0
            var failures = 0
            var copied = Set<String>()
            let nextOffset = try LineReader.readCompleteLines(at: ref.url, from: file.offset) { line in
                lines += 1
                switch RecordParser.parse(line) {
                case .notCandidate:
                    return
                case .rejected:
                    candidates += 1
                case .malformed:
                    candidates += 1
                    failures += 1
                case .compaction(let timestamp):
                    candidates += 1
                    try db.statement("INSERT INTO marks(file_id, seq, ts) VALUES(?, ?, ?)")
                        .bind(.int(file.id), .int(seq), .optionalDouble(timestamp)).run()
                    seq += 1
                case .title(let sessionID, let title):
                    candidates += 1
                    try upsertTitle(sessionID: sessionID, title: title, birthtime: file.birthtime, seq: seq)
                case .call(let call):
                    candidates += 1
                    // R5: one occurrence per message id per file.
                    try db.statement(
                        """
                        INSERT INTO occurrences(file_id, message_id, seq, line_session_id) VALUES(?, ?, ?, ?)
                        ON CONFLICT(file_id, message_id) DO NOTHING
                        """
                    ).bind(.int(file.id), .text(call.messageID), .int(seq), .optionalText(call.lineSessionID)).run()
                    guard db.changes > 0 else { return }
                    seq += 1
                    if try insertCall(call, ownerFileID: file.id) {
                        summary.callsAdded += 1
                    } else {
                        copied.insert(call.messageID)  // seen in another file: settle the owner below
                    }
                }
            }
            for messageID in copied { try settleOwner(of: messageID) }
            summary.parseFailures = failures
            try db.statement(
                """
                UPDATE files SET size = ?, offset = ?, next_seq = ?, lines_read = lines_read + ?,
                candidate_lines = candidate_lines + ?, parse_failures = parse_failures + ? WHERE id = ?
                """
            ).bind(
                .int(Int64(max(stat.size, nextOffset))), .int(Int64(nextOffset)), .int(seq), .int(lines),
                .int(candidates), .int(failures), .int(file.id)
            ).run()
            return summary
        }
    }

    // MARK: - Queries

    public func stats(from: Double, to: Double) throws -> UsageTotals {
        let s = try db.statement(
            """
            SELECT COUNT(*), COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0),
            COALESCE(SUM(cache_read_tokens), 0), COALESCE(SUM(cache_write_tokens), 0)
            FROM calls WHERE ts >= ? AND ts < ?
            """
        ).bind(.double(from), .double(to))
        guard try s.step() else { return UsageTotals() }
        return UsageTotals(
            calls: s.int(0), inputTokens: s.int(1), outputTokens: s.int(2), cacheReadTokens: s.int(3),
            cacheWriteTokens: s.int(4))
    }

    /// The file whose copy of the call is counted (rule R4).
    public func owner(of messageID: String) throws -> URL? {
        let s = try db.statement(
            "SELECT f.path FROM calls c JOIN files f ON f.id = c.owner_file_id WHERE c.message_id = ?"
        ).bind(.text(messageID))
        return try s.step() ? URL(fileURLWithPath: s.text(0)) : nil
    }

    /// Calls and compaction marks of one file, in file order.
    public func timeline(of file: URL) throws -> [TimelineEvent] {
        guard let row = try fileRow(path: TranscriptLocator.canonical(file).path) else { return [] }
        var events: [TimelineEvent] = []
        let calls = try db.statement(
            """
            SELECT o.seq, c.message_id, c.ts, c.model, c.version, o.line_session_id, c.input_tokens,
            c.output_tokens, c.cache_read_tokens, c.cache_write_tokens, c.cache_write_1h, c.cache_write_5m,
            c.ttl, c.owner_file_id
            FROM occurrences o JOIN calls c ON c.message_id = o.message_id WHERE o.file_id = ?
            """
        ).bind(.int(row.id))
        while try calls.step() {
            let record = CallRecord(
                messageID: calls.text(1), timestamp: calls.double(2), model: calls.text(3),
                version: calls.optionalText(4), lineSessionID: calls.optionalText(5),
                inputTokens: calls.int(6), outputTokens: calls.int(7), cacheReadTokens: calls.int(8),
                cacheWriteTokens: calls.int(9), cacheWrite1h: calls.int(10), cacheWrite5m: calls.int(11),
                ttl: calls.optionalText(12).flatMap(CacheTTL.init(rawValue:)))
            events.append(TimelineEvent(seq: calls.int(0), kind: .call(record, owned: calls.int(13) == row.id)))
        }
        let marks = try db.statement("SELECT seq, ts FROM marks WHERE file_id = ?").bind(.int(row.id))
        while try marks.step() {
            events.append(TimelineEvent(seq: marks.int(0), kind: .compaction(timestamp: marks.optionalDouble(1))))
        }
        return events.sorted { $0.seq < $1.seq }
    }

    public func title(of sessionID: String) throws -> String? {
        let s = try db.statement("SELECT title FROM titles WHERE session_id = ?").bind(.text(sessionID))
        return try s.step() ? s.text(0) : nil
    }

    // MARK: - Storage

    private struct FileRow {
        var id: Int
        var inode: UInt64
        var birthtime: Double
        var offset: UInt64
        var nextSeq: Int
    }

    private func prepareSchema() throws {
        try db.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        try db.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        let version = try db.statement("SELECT value FROM meta WHERE key = 'schema_version'")
        let current = try version.step() ? version.text(0) : nil
        guard current != Self.schemaVersion else { return }
        // The index is derived data: rebuild it rather than migrate.
        try db.execute(
            """
            DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS calls; DROP TABLE IF EXISTS occurrences;
            DROP TABLE IF EXISTS marks; DROP TABLE IF EXISTS titles;
            CREATE TABLE files(
                id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, session_id TEXT NOT NULL,
                agent_id TEXT, inode INTEGER NOT NULL, birthtime REAL NOT NULL, size INTEGER NOT NULL DEFAULT 0,
                offset INTEGER NOT NULL DEFAULT 0, next_seq INTEGER NOT NULL DEFAULT 0,
                lines_read INTEGER NOT NULL DEFAULT 0, candidate_lines INTEGER NOT NULL DEFAULT 0,
                parse_failures INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE calls(
                message_id TEXT PRIMARY KEY, owner_file_id INTEGER NOT NULL, ts REAL NOT NULL, model TEXT NOT NULL,
                version TEXT, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
                cache_read_tokens INTEGER NOT NULL, cache_write_tokens INTEGER NOT NULL,
                cache_write_1h INTEGER NOT NULL, cache_write_5m INTEGER NOT NULL, ttl TEXT);
            CREATE INDEX calls_ts ON calls(ts);
            CREATE TABLE occurrences(
                file_id INTEGER NOT NULL, message_id TEXT NOT NULL, seq INTEGER NOT NULL, line_session_id TEXT,
                PRIMARY KEY(file_id, message_id));
            CREATE INDEX occurrences_message ON occurrences(message_id);
            CREATE TABLE marks(file_id INTEGER NOT NULL, seq INTEGER NOT NULL, ts REAL, PRIMARY KEY(file_id, seq));
            CREATE TABLE titles(
                session_id TEXT PRIMARY KEY, title TEXT NOT NULL, file_birthtime REAL NOT NULL, seq INTEGER NOT NULL);
            """)
        try db.statement("INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)")
            .bind(.text(Self.schemaVersion)).run()
    }

    private func fileRow(path: String) throws -> FileRow? {
        let s = try db.statement("SELECT id, inode, birthtime, offset, next_seq FROM files WHERE path = ?")
            .bind(.text(path))
        guard try s.step() else { return nil }
        return FileRow(
            id: s.int(0), inode: UInt64(bitPattern: Int64(s.int(1))), birthtime: s.double(2),
            offset: UInt64(s.int(3)), nextSeq: s.int(4))
    }

    private func insertFile(_ ref: TranscriptRef, _ stat: FileStat) throws -> FileRow {
        try db.statement(
            "INSERT INTO files(path, kind, session_id, agent_id, inode, birthtime) VALUES(?, ?, ?, ?, ?, ?)"
        ).bind(
            .text(ref.url.path), .text(ref.kind.rawValue), .text(ref.sessionID), .optionalText(ref.agentID),
            .int(Int64(bitPattern: stat.inode)), .double(stat.birthtime)
        ).run()
        guard let row = try fileRow(path: ref.url.path) else { throw SQLiteError(code: -1, message: "insert lost") }
        return row
    }

    /// Returns false when the call already exists because another file has a copy of it.
    private func insertCall(_ call: CallRecord, ownerFileID: Int) throws -> Bool {
        try db.statement(
            """
            INSERT INTO calls(message_id, owner_file_id, ts, model, version, input_tokens, output_tokens,
            cache_read_tokens, cache_write_tokens, cache_write_1h, cache_write_5m, ttl)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(message_id) DO NOTHING
            """
        ).bind(
            .text(call.messageID), .int(ownerFileID), .double(call.timestamp), .text(call.model),
            .optionalText(call.version), .int(call.inputTokens), .int(call.outputTokens), .int(call.cacheReadTokens),
            .int(call.cacheWriteTokens), .int(call.cacheWrite1h), .int(call.cacheWrite5m),
            .optionalText(call.ttl?.rawValue)
        ).run()
        return db.changes > 0
    }

    private func upsertTitle(sessionID: String, title: String, birthtime: Double, seq: Int) throws {
        // R11: a title from a newer file, or later in the same file, wins.
        try db.statement(
            """
            INSERT INTO titles(session_id, title, file_birthtime, seq) VALUES(?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET title = excluded.title,
                file_birthtime = excluded.file_birthtime, seq = excluded.seq
            WHERE (excluded.file_birthtime, excluded.seq) >= (titles.file_birthtime, titles.seq)
            """
        ).bind(.text(sessionID), .text(title), .double(birthtime), .int(seq)).run()
    }

    /// R4: the owner is the occurrence with the smallest key
    /// (main file whose name matches the line's sessionId first, then earliest created, then path).
    /// A call with no occurrences left is deleted (R8).
    private func settleOwner(of messageID: String) throws {
        let s = try db.statement(
            """
            SELECT o.file_id, f.kind, f.session_id, o.line_session_id, f.birthtime, f.path
            FROM occurrences o JOIN files f ON f.id = o.file_id WHERE o.message_id = ?
            """
        ).bind(.text(messageID))
        var best: (rank: Int, birthtime: Double, path: String, fileID: Int)?
        while try s.step() {
            let matches = s.text(1) == TranscriptKind.main.rawValue && s.optionalText(3) == s.text(2)
            let key = (rank: matches ? 0 : 1, birthtime: s.double(4), path: s.text(5), fileID: s.int(0))
            if let current = best,
                (current.rank, current.birthtime, current.path) <= (key.rank, key.birthtime, key.path)
            {
                continue
            }
            best = key
        }
        if let best {
            try db.statement("UPDATE calls SET owner_file_id = ? WHERE message_id = ?")
                .bind(.int(best.fileID), .text(messageID)).run()
        } else {
            try db.statement("DELETE FROM calls WHERE message_id = ?").bind(.text(messageID)).run()
        }
    }

    /// Forgets everything read from a file, so it can be read again from the start.
    private func resetFile(_ file: FileRow) throws {
        var messageIDs: [String] = []
        let s = try db.statement("SELECT message_id FROM occurrences WHERE file_id = ?").bind(.int(file.id))
        while try s.step() { messageIDs.append(s.text(0)) }
        try db.statement("DELETE FROM occurrences WHERE file_id = ?").bind(.int(file.id)).run()
        try db.statement("DELETE FROM marks WHERE file_id = ?").bind(.int(file.id)).run()
        for messageID in messageIDs { try settleOwner(of: messageID) }
        try db.statement(
            """
            UPDATE files SET offset = 0, next_seq = 0, size = 0, lines_read = 0, candidate_lines = 0,
            parse_failures = 0 WHERE id = ?
            """
        ).bind(.int(file.id)).run()
    }

    private func removeFile(path: String) throws {
        try db.transaction {
            guard let file = try fileRow(path: path) else { return }
            try resetFile(file)
            try db.statement("DELETE FROM files WHERE id = ?").bind(.int(file.id)).run()
        }
    }

    private func knownPaths(under prefix: String? = nil) throws -> [String] {
        var paths: [String] = []
        let s = try db.statement("SELECT path FROM files")
        while try s.step() { paths.append(s.text(0)) }
        guard let prefix else { return paths }
        return paths.filter { $0 == prefix || $0.hasPrefix(prefix + "/") }
    }
}

/// The file attributes the indexer needs.
struct FileStat {
    var inode: UInt64
    var size: UInt64
    var birthtime: Double
    var modified: Double

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return nil }
        self.inode = inode
        self.size = size
        birthtime = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }
}
