import Foundation

/// Token totals for calls whose timestamp falls in a window.
public struct UsageTotals: Sendable, Equatable {
    public var calls = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWriteTokens = 0
}

/// A file the indexer could not read this time. It is retried on the next scan or event.
public struct SkippedFile: Sendable, Equatable {
    public var path: String
    public var reason: String
}

public struct IndexSummary: Sendable, Equatable {
    public var filesScanned = 0
    public var filesRead = 0
    public var filesRemoved = 0
    public var callsAdded = 0
    public var parseFailures = 0
    public var skippedFiles: [SkippedFile] = []

    mutating func add(_ other: IndexSummary) {
        filesScanned += other.filesScanned
        filesRead += other.filesRead
        filesRemoved += other.filesRemoved
        callsAdded += other.callsAdded
        parseFailures += other.parseFailures
        skippedFiles += other.skippedFiles
    }
}

/// One event in a transcript, in file order.
public struct TimelineEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The call as written in this file. `owned` is false when the call was copied here
        /// and is counted in another file.
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
    private static let schemaVersion = "3"
    /// Bytes at the start of a file that are fingerprinted to notice in-place rewrites.
    private static let headLimit = 1024

    public init(root: URL, databaseURL: URL) throws {
        self.root = TranscriptLocator.canonical(root)
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            db = try Indexer.open(databaseURL)
        } catch let error as SQLiteError where error.isCorruption {
            // The index is derived data: a damaged file is replaced, never repaired.
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
            }
            db = try Indexer.open(databaseURL)
        }
    }

    // MARK: - Indexing

    /// Scans the whole root: reads new and changed files, newest first, and forgets deleted ones.
    /// A file that cannot be read is reported in `skippedFiles` and does not stop the scan.
    @discardableResult
    public func indexAll() throws -> IndexSummary {
        var summary = IndexSummary()
        let scan = TranscriptLocator.findAll(root: root)
        let present = Set(scan.refs.map(\.url.path))
        for path in try knownPaths() where !present.contains(path) && !scan.isUnderUnreadableDirectory(path) {
            try removeFile(path: path)
            summary.filesRemoved += 1
        }
        let stated = scan.refs.compactMap { ref in FileStat(ref.url).map { (ref, $0) } }
        for (ref, stat) in stated.sorted(by: { $0.1.modified > $1.1.modified }) {
            summary.add(try indexSkippingFailures(ref, stat))
        }
        try db.run(
            "INSERT OR REPLACE INTO meta(key, value) VALUES('last_full_index_at', ?)",
            [.text(String(Date().timeIntervalSince1970))])
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
                // Gone, unless we merely cannot look inside its folder any more.
                guard Indexer.isSearchable(path.deletingLastPathComponent()) else { continue }
                for known in try knownPaths(under: path.path) {
                    try removeFile(path: known)
                    summary.filesRemoved += 1
                }
                continue
            }
            let scan =
                isDirectory.boolValue
                ? TranscriptLocator.findAll(root: root, under: path)
                : TranscriptScan(refs: [TranscriptLocator.classify(path, root: root)].compactMap { $0 })
            for ref in scan.refs where handled.insert(ref.url.path).inserted {
                if let stat = FileStat(ref.url) { summary.add(try indexSkippingFailures(ref, stat)) }
            }
            if isDirectory.boolValue {
                let present = Set(scan.refs.map(\.url.path))
                for known in try knownPaths(under: path.path)
                where !present.contains(known) && !scan.isUnderUnreadableDirectory(known) {
                    try removeFile(path: known)
                    summary.filesRemoved += 1
                }
            }
        }
        return summary
    }

    /// File problems (permissions, a file vanishing mid-read) skip that file; index problems throw.
    private func indexSkippingFailures(_ ref: TranscriptRef, _ stat: FileStat) throws -> IndexSummary {
        do {
            return try index(ref, stat)
        } catch let error as SQLiteError {
            throw error
        } catch {
            return IndexSummary(
                filesScanned: 1, skippedFiles: [SkippedFile(path: ref.url.path, reason: error.localizedDescription)])
        }
    }

    private func index(_ ref: TranscriptRef, _ stat: FileStat) throws -> IndexSummary {
        try db.transaction {
            var summary = IndexSummary(filesScanned: 1)
            var file = try fileRow(path: ref.url.path) ?? insertFile(ref, stat)
            if try file.inode != stat.inode || stat.size < file.offset || headChanged(file, at: ref.url) {
                try resetFile(file)  // R7: replaced, truncated or rewritten in place
                file.offset = 0
                file.nextSeq = 0
            }
            file.inode = stat.inode
            file.birthtime = stat.birthtime
            try db.run(
                "UPDATE files SET inode = ?, birthtime = ? WHERE id = ?",
                [.int(Int64(bitPattern: file.inode)), .double(file.birthtime), .int(file.id)])
            guard stat.size > file.offset else { return summary }

            var seq = file.nextSeq
            var lines = 0
            var candidates = 0
            var failures = 0
            var unsettled = Set<String>()
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
                    try db.run(
                        "INSERT INTO marks(file_id, seq, ts) VALUES(?, ?, ?)",
                        [.int(file.id), .int(seq), .optionalDouble(timestamp)])
                    seq += 1
                case .title(let sessionID, let title):
                    candidates += 1
                    try db.run(
                        "INSERT INTO titles(file_id, seq, session_id, title) VALUES(?, ?, ?, ?)",
                        [.int(file.id), .int(seq), .text(sessionID), .text(title)])
                case .call(let call):
                    candidates += 1
                    switch try recordOccurrence(call, fileID: file.id, seq: seq) {
                    case .inserted:
                        seq += 1
                        if try insertCall(call, ownerFileID: file.id) {
                            summary.callsAdded += 1
                        } else {
                            unsettled.insert(call.messageID)  // also in another file: settle the owner below
                        }
                    case .updated:
                        unsettled.insert(call.messageID)  // the owner's values may have changed
                    case .unchanged:
                        break
                    }
                }
            }
            for messageID in unsettled { try settleOwner(of: messageID) }
            if nextOffset > file.offset { summary.filesRead = 1 }
            summary.parseFailures = failures
            let head = try Indexer.head(of: ref.url, length: min(Indexer.headLimit, Int(nextOffset)))
            try db.run(
                """
                UPDATE files SET size = ?, offset = ?, next_seq = ?, head_length = ?, head_hash = ?,
                lines_read = lines_read + ?, candidate_lines = candidate_lines + ?,
                parse_failures = parse_failures + ? WHERE id = ?
                """,
                [
                    .int(Int64(max(stat.size, nextOffset))), .int(Int64(nextOffset)), .int(seq), .int(head.length),
                    .int(head.hash), .int(lines), .int(candidates), .int(failures), .int(file.id),
                ])
            return summary
        }
    }

    // MARK: - Queries

    public func stats(from: Double, to: Double) throws -> UsageTotals {
        try db.queryRow(
            """
            SELECT COUNT(*), COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0),
            COALESCE(SUM(cache_read_tokens), 0), COALESCE(SUM(cache_write_tokens), 0)
            FROM calls WHERE ts >= ? AND ts < ?
            """, [.double(from), .double(to)]
        ) { row in
            UsageTotals(
                calls: row.int(0), inputTokens: row.int(1), outputTokens: row.int(2), cacheReadTokens: row.int(3),
                cacheWriteTokens: row.int(4))
        } ?? UsageTotals()
    }

    /// Files that own at least one call in `[from, to)`, for analysis.
    public func ownedFiles(from: Double, to: Double) throws -> [TranscriptRef] {
        var refs: [TranscriptRef] = []
        try db.query(
            """
            SELECT DISTINCT f.path, f.kind, f.session_id, f.agent_id
            FROM calls c JOIN files f ON f.id = c.owner_file_id WHERE c.ts >= ? AND c.ts < ? ORDER BY f.path
            """, [.double(from), .double(to)]
        ) { s in
            refs.append(
                TranscriptRef(
                    url: URL(fileURLWithPath: s.text(0)), kind: TranscriptKind(rawValue: s.text(1)) ?? .main,
                    sessionID: s.text(2), agentID: s.optionalText(3)))
        }
        return refs
    }

    /// The file whose copy of the call is counted (rule R4).
    public func owner(of messageID: String) throws -> URL? {
        try db.queryRow(
            "SELECT f.path FROM calls c JOIN files f ON f.id = c.owner_file_id WHERE c.message_id = ?",
            [.text(messageID)]
        ) { URL(fileURLWithPath: $0.text(0)) }
    }

    /// Calls and compaction marks of one file, in file order, with the values written in that file.
    public func timeline(of file: URL) throws -> [TimelineEvent] {
        guard let row = try fileRow(path: TranscriptLocator.canonical(file).path) else { return [] }
        var events: [TimelineEvent] = []
        try db.query(
            """
            SELECT o.seq, o.message_id, o.ts, o.model, o.version, o.line_session_id, o.input_tokens,
            o.output_tokens, o.cache_read_tokens, o.cache_write_tokens, o.cache_write_1h, o.cache_write_5m,
            o.ttl, c.owner_file_id, o.iterations
            FROM occurrences o JOIN calls c ON c.message_id = o.message_id WHERE o.file_id = ?
            """, [.int(row.id)]
        ) { s in
            let record = CallRecord(
                messageID: s.text(1), timestamp: s.double(2), model: s.text(3), version: s.optionalText(4),
                lineSessionID: s.optionalText(5), inputTokens: s.int(6), outputTokens: s.int(7),
                cacheReadTokens: s.int(8), cacheWriteTokens: s.int(9), cacheWrite1h: s.int(10),
                cacheWrite5m: s.int(11), ttl: s.optionalText(12).flatMap(CacheTTL.init(rawValue:)),
                iterations: Indexer.decodeIterations(s.optionalText(14)))
            events.append(TimelineEvent(seq: s.int(0), kind: .call(record, owned: s.int(13) == row.id)))
        }
        try db.query("SELECT seq, ts FROM marks WHERE file_id = ?", [.int(row.id)]) { s in
            events.append(TimelineEvent(seq: s.int(0), kind: .compaction(timestamp: s.optionalDouble(1))))
        }
        return events.sorted { $0.seq < $1.seq }
    }

    /// The latest title: from the newest file, and the last one in that file (R11).
    public func title(of sessionID: String) throws -> String? {
        try db.queryRow(
            """
            SELECT t.title FROM titles t JOIN files f ON f.id = t.file_id WHERE t.session_id = ?
            ORDER BY f.birthtime DESC, t.seq DESC, t.id DESC LIMIT 1
            """, [.text(sessionID)]
        ) { $0.text(0) }
    }

    /// Calls whose copies disagree on token counts. Expected to be zero; counted so a format change shows up.
    public func usageMismatchCount() throws -> Int {
        try db.queryRow(
            """
            SELECT COUNT(*) FROM (SELECT message_id FROM occurrences GROUP BY message_id
            HAVING COUNT(DISTINCT input_tokens || '/' || output_tokens || '/' || cache_read_tokens || '/'
            || cache_write_tokens) > 1)
            """
        ) { $0.int(0) } ?? 0
    }

    // MARK: - Storage

    private struct FileRow {
        var id: Int
        var inode: UInt64
        var birthtime: Double
        var offset: UInt64
        var nextSeq: Int
        var headLength: Int
        var headHash: Int64
    }

    private static func open(_ url: URL) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        try db.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        let current = try db.queryRow("SELECT value FROM meta WHERE key = 'schema_version'") { $0.text(0) }
        guard current != schemaVersion else { return db }
        // The index is derived data: rebuild it rather than migrate.
        try db.execute(
            """
            DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS calls; DROP TABLE IF EXISTS occurrences;
            DROP TABLE IF EXISTS marks; DROP TABLE IF EXISTS titles;
            CREATE TABLE files(
                id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, session_id TEXT NOT NULL,
                agent_id TEXT, inode INTEGER NOT NULL, birthtime REAL NOT NULL, size INTEGER NOT NULL DEFAULT 0,
                offset INTEGER NOT NULL DEFAULT 0, next_seq INTEGER NOT NULL DEFAULT 0,
                head_length INTEGER NOT NULL DEFAULT 0, head_hash INTEGER NOT NULL DEFAULT 0,
                lines_read INTEGER NOT NULL DEFAULT 0, candidate_lines INTEGER NOT NULL DEFAULT 0,
                parse_failures INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE occurrences(
                file_id INTEGER NOT NULL, message_id TEXT NOT NULL, seq INTEGER NOT NULL, line_session_id TEXT,
                ts REAL NOT NULL, model TEXT NOT NULL, version TEXT, input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL, cache_read_tokens INTEGER NOT NULL,
                cache_write_tokens INTEGER NOT NULL, cache_write_1h INTEGER NOT NULL,
                cache_write_5m INTEGER NOT NULL, ttl TEXT, iterations TEXT, PRIMARY KEY(file_id, message_id));
            CREATE INDEX occurrences_message ON occurrences(message_id);
            CREATE TABLE calls(
                message_id TEXT PRIMARY KEY, owner_file_id INTEGER NOT NULL, ts REAL NOT NULL,
                input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL, cache_read_tokens INTEGER NOT NULL,
                cache_write_tokens INTEGER NOT NULL);
            CREATE INDEX calls_ts ON calls(ts);
            CREATE TABLE marks(file_id INTEGER NOT NULL, seq INTEGER NOT NULL, ts REAL, PRIMARY KEY(file_id, seq));
            CREATE TABLE titles(
                id INTEGER PRIMARY KEY, file_id INTEGER NOT NULL, seq INTEGER NOT NULL, session_id TEXT NOT NULL,
                title TEXT NOT NULL);
            CREATE INDEX titles_session ON titles(session_id);
            """)
        try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)", [.text(schemaVersion)])
        return db
    }

    private func fileRow(path: String) throws -> FileRow? {
        try db.queryRow(
            "SELECT id, inode, birthtime, offset, next_seq, head_length, head_hash FROM files WHERE path = ?",
            [.text(path)]
        ) { s in
            FileRow(
                id: s.int(0), inode: UInt64(bitPattern: Int64(s.int(1))), birthtime: s.double(2),
                offset: UInt64(s.int(3)), nextSeq: s.int(4), headLength: s.int(5), headHash: Int64(s.int(6)))
        }
    }

    private func insertFile(_ ref: TranscriptRef, _ stat: FileStat) throws -> FileRow {
        try db.run(
            "INSERT INTO files(path, kind, session_id, agent_id, inode, birthtime) VALUES(?, ?, ?, ?, ?, ?)",
            [
                .text(ref.url.path), .text(ref.kind.rawValue), .text(ref.sessionID), .optionalText(ref.agentID),
                .int(Int64(bitPattern: stat.inode)), .double(stat.birthtime),
            ])
        guard let row = try fileRow(path: ref.url.path) else { throw SQLiteError(code: -1, message: "insert lost") }
        return row
    }

    private enum OccurrenceChange {
        case inserted
        case updated
        case unchanged
    }

    /// R5: a message's first line in a file fixes its place, time, model and version there. Claude Code writes
    /// a line per content block and fills in the usage as the response streams, so each later line of the same
    /// message replaces the usage, and the last line's usage is final.
    private func recordOccurrence(_ call: CallRecord, fileID: Int, seq: Int) throws -> OccurrenceChange {
        let usage: [SQLValue] = [
            .int(call.inputTokens), .int(call.outputTokens), .int(call.cacheReadTokens), .int(call.cacheWriteTokens),
            .int(call.cacheWrite1h), .int(call.cacheWrite5m), .optionalText(call.ttl?.rawValue),
            .optionalText(Indexer.encodeIterations(call.iterations)),
        ]
        try db.run(
            """
            INSERT INTO occurrences(file_id, message_id, seq, line_session_id, ts, model, version, input_tokens,
            output_tokens, cache_read_tokens, cache_write_tokens, cache_write_1h, cache_write_5m, ttl, iterations)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(file_id, message_id) DO NOTHING
            """,
            [
                .int(fileID), .text(call.messageID), .int(seq), .optionalText(call.lineSessionID),
                .double(call.timestamp), .text(call.model), .optionalText(call.version),
            ] + usage)
        if db.changes > 0 { return .inserted }
        try db.run(
            """
            UPDATE occurrences SET input_tokens = ?, output_tokens = ?, cache_read_tokens = ?, cache_write_tokens = ?,
            cache_write_1h = ?, cache_write_5m = ?, ttl = ?, iterations = ?
            WHERE file_id = ? AND message_id = ? AND (input_tokens IS NOT ? OR output_tokens IS NOT ?
            OR cache_read_tokens IS NOT ? OR cache_write_tokens IS NOT ? OR cache_write_1h IS NOT ?
            OR cache_write_5m IS NOT ? OR ttl IS NOT ? OR iterations IS NOT ?)
            """, usage + [.int(fileID), .text(call.messageID)] + usage)
        return db.changes > 0 ? .updated : .unchanged
    }

    private static func encodeIterations(_ iterations: [UsagePart]) -> String? {
        guard !iterations.isEmpty, let data = try? JSONEncoder().encode(iterations) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeIterations(_ text: String?) -> [UsagePart] {
        guard let text else { return [] }
        return (try? JSONDecoder().decode([UsagePart].self, from: Data(text.utf8))) ?? []
    }

    /// Returns false when the call already exists because another file has a copy of it.
    private func insertCall(_ call: CallRecord, ownerFileID: Int) throws -> Bool {
        try db.run(
            """
            INSERT INTO calls(message_id, owner_file_id, ts, input_tokens, output_tokens, cache_read_tokens,
            cache_write_tokens) VALUES(?, ?, ?, ?, ?, ?, ?) ON CONFLICT(message_id) DO NOTHING
            """,
            [
                .text(call.messageID), .int(ownerFileID), .double(call.timestamp), .int(call.inputTokens),
                .int(call.outputTokens), .int(call.cacheReadTokens), .int(call.cacheWriteTokens),
            ])
        return db.changes > 0
    }

    /// R4: the owner is the occurrence with the smallest key (main file whose name matches the line's
    /// sessionId first, then earliest created, then path). The counted values are the owner's, so the
    /// result does not depend on reading order. A call with no occurrences left is deleted (R8).
    private func settleOwner(of messageID: String) throws {
        struct Candidate {
            var rank: Int
            var birthtime: Double
            var path: String
            var fileID: Int
            var values: [SQLValue]
        }
        var best: Candidate?
        try db.query(
            """
            SELECT o.file_id, f.kind, f.session_id, o.line_session_id, f.birthtime, f.path,
            o.ts, o.input_tokens, o.output_tokens, o.cache_read_tokens, o.cache_write_tokens
            FROM occurrences o JOIN files f ON f.id = o.file_id WHERE o.message_id = ?
            """, [.text(messageID)]
        ) { s in
            let matches = s.text(1) == TranscriptKind.main.rawValue && s.optionalText(3) == s.text(2)
            let candidate = Candidate(
                rank: matches ? 0 : 1, birthtime: s.double(4), path: s.text(5), fileID: s.int(0),
                values: [.double(s.double(6)), .int(s.int(7)), .int(s.int(8)), .int(s.int(9)), .int(s.int(10))])
            if let current = best,
                (current.rank, current.birthtime, current.path) <= (candidate.rank, candidate.birthtime, candidate.path)
            {
                return
            }
            best = candidate
        }
        if let best {
            try db.run(
                """
                UPDATE calls SET owner_file_id = ?, ts = ?, input_tokens = ?, output_tokens = ?,
                cache_read_tokens = ?, cache_write_tokens = ? WHERE message_id = ?
                """, [.int(best.fileID)] + best.values + [.text(messageID)])
        } else {
            try db.run("DELETE FROM calls WHERE message_id = ?", [.text(messageID)])
        }
    }

    /// Forgets everything read from a file, so it can be read again from the start.
    private func resetFile(_ file: FileRow) throws {
        var messageIDs: [String] = []
        try db.query("SELECT message_id FROM occurrences WHERE file_id = ?", [.int(file.id)]) {
            messageIDs.append($0.text(0))
        }
        for table in ["occurrences", "marks", "titles"] {
            try db.run("DELETE FROM \(table) WHERE file_id = ?", [.int(file.id)])
        }
        for messageID in messageIDs { try settleOwner(of: messageID) }
        try db.run(
            """
            UPDATE files SET offset = 0, next_seq = 0, size = 0, head_length = 0, head_hash = 0,
            lines_read = 0, candidate_lines = 0, parse_failures = 0 WHERE id = ?
            """, [.int(file.id)])
    }

    private func removeFile(path: String) throws {
        try db.transaction {
            guard let file = try fileRow(path: path) else { return }
            try resetFile(file)
            try db.run("DELETE FROM files WHERE id = ?", [.int(file.id)])
        }
    }

    private func knownPaths(under prefix: String? = nil) throws -> [String] {
        var paths: [String] = []
        try db.query("SELECT path FROM files") { paths.append($0.text(0)) }
        guard let prefix else { return paths }
        return paths.filter { $0 == prefix || $0.hasPrefix(prefix + "/") }
    }

    /// True when the bytes already read no longer start the file (rewritten in place, same inode).
    private func headChanged(_ file: FileRow, at url: URL) throws -> Bool {
        guard file.offset > 0, file.headLength > 0 else { return false }
        let head = try Indexer.head(of: url, length: file.headLength)
        return head.length != file.headLength || head.hash != file.headHash
    }

    private static func head(of url: URL, length: Int) throws -> (length: Int, hash: Int64) {
        guard length > 0 else { return (0, 0) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: length) ?? Data()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a 64
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return (bytes.count, Int64(bitPattern: hash))
    }

    /// Whether a missing file inside this folder is really gone. A folder that exists but cannot be
    /// listed hides its files without deleting them; a folder that is gone took its files with it.
    private static func isSearchable(_ directory: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return true }
        return FileManager.default.isExecutableFile(atPath: directory.path)
            && FileManager.default.isReadableFile(atPath: directory.path)
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
