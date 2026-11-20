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

/// How an index file is opened (R-1). The index is derived data, but only the app's own file may be replaced.
public enum IndexOpening: Sendable, Equatable {
    /// A path someone chose (the CLI's --db): a file this app did not make is left alone and reported.
    case refuseUnknown
    /// The app's own index: a damaged or unknown file there is replaced.
    case replaceUnusable
    /// The app's own index after damage found while running: start over even if the file opens.
    case startOver
}

public enum IndexOpenError: Error, Equatable, CustomStringConvertible {
    case notAnIndex(String)
    case insideReadOnlyFolder(database: String, folder: String)
    case unresolvablePath(String)

    public var description: String {
        switch self {
        case .notAnIndex(let path): "\(path) is not a Tokens Are Running Out index; it was left unchanged."
        case .insideReadOnlyFolder(_, let folder):
            "The index cannot live inside \(folder); it must stay read-only."
        case .unresolvablePath(let path): "\(path) has too many symbolic links to follow."
        }
    }
}

/// R9: the index never lives where Claude Code's data or the transcripts are.
public enum IndexLocation {
    public static func check(database: URL, root: URL, home: URL) throws(IndexOpenError) {
        let path = try physical(database)
        for folder in [home.appendingPathComponent(".claude"), root] where try isInside(path, folder) {
            throw .insideReadOnlyFolder(database: database.path, folder: folder.standardizedFileURL.path)
        }
    }

    /// The path the system actually reaches: every link followed in order, even one whose target does not
    /// exist yet, and `..` applied after the links before it. The index is checked, created and opened at this
    /// one path, so the path checked is the path written.
    public static func physical(_ url: URL) throws(IndexOpenError) -> URL {
        var resolved: [String] = []
        var pending = url.path.split(separator: "/").map(String.init)
        var links = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            }
            let candidate = "/" + (resolved + [part]).joined(separator: "/")
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) else {
                resolved.append(part)
                continue
            }
            links += 1
            guard links <= 40 else { throw .unresolvablePath(url.path) }
            if target.hasPrefix("/") { resolved = [] }
            pending = target.split(separator: "/").map(String.init) + pending
        }
        return URL(fileURLWithPath: "/" + resolved.joined(separator: "/"))
    }

    /// Inside by spelling, ignoring letter case (APFS ignores it by default, so `~/.CLAUDE` is `~/.claude`), or
    /// inside the same folder reached another way (a firmlink such as `/System/Volumes/Data`, another Unicode
    /// form): an existing ancestor with the folder's device and inode. On a case-sensitive volume this refuses
    /// a little more than it must.
    private static func isInside(_ path: URL, _ folder: URL) throws(IndexOpenError) -> Bool {
        let folder = try physical(folder)
        let (spelled, inside) = (path.path.lowercased(), folder.path.lowercased())
        if spelled == inside || spelled.hasPrefix(inside == "/" ? "/" : inside + "/") { return true }
        guard let target = identity(of: folder) else { return false }
        var ancestor = path
        while true {
            if identity(of: ancestor) == target { return true }
            guard ancestor.path != "/" else { return false }
            ancestor.deleteLastPathComponent()
        }
    }

    private static func identity(of url: URL) -> [UInt64]? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return [UInt64(UInt32(bitPattern: info.st_dev)), info.st_ino]
    }
}

public struct IndexSummary: Sendable, Equatable {
    public var filesScanned = 0
    public var filesRead = 0
    /// Files emptied, replaced or rewritten: their old calls are gone even if nothing new was read.
    public var filesReset = 0
    public var filesRemoved = 0
    public var callsAdded = 0
    public var parseFailures = 0
    public var skippedFiles: [SkippedFile] = []

    mutating func add(_ other: IndexSummary) {
        filesScanned += other.filesScanned
        filesRead += other.filesRead
        filesReset += other.filesReset
        filesRemoved += other.filesRemoved
        callsAdded += other.callsAdded
        parseFailures += other.parseFailures
        skippedFiles += other.skippedFiles
    }
}

/// Bytes read so far in one `indexAll`, for a progress bar.
public struct IndexProgress: Sendable, Equatable {
    public var bytesRead: Int64
    public var bytesTotal: Int64
    /// True when the index was empty: the first index after install or a schema change.
    public var isInitial: Bool

    public init(bytesRead: Int64, bytesTotal: Int64, isInitial: Bool) {
        self.bytesRead = bytesRead
        self.bytesTotal = bytesTotal
        self.isInitial = isInitial
    }
}

/// Whether recent transcript lines still parse into calls (2-3 BR-H1).
public struct IndexHealth: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case none
        /// More than 5% of recent assistant lines were not calls.
        case unreadableLines(share: Double)
        /// Main transcripts grew by 200 lines or more with no calls.
        case noCalls
    }

    public var assistantLines = 0
    public var assistantWithoutCall = 0
    public var mainLinesAppended = 0
    public var mainCallsAppended = 0
    public var kind = Kind.none

    public init() {}
}

/// A session's latest call, for its cache expiry (2-3 BR-E2, BR-E3).
public struct LastCall: Sendable, Equatable {
    public var sessionID: String
    public var file: URL
    public var timestamp: Double
    public var ttl: CacheTTL
    public var model: String
    public var contextTokens: Int
    public var title: String?

    public init(
        sessionID: String, file: URL, timestamp: Double, ttl: CacheTTL, model: String, contextTokens: Int,
        title: String?
    ) {
        self.sessionID = sessionID
        self.file = file
        self.timestamp = timestamp
        self.ttl = ttl
        self.model = model
        self.contextTokens = contextTokens
        self.title = title
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
    private static let schemaVersion = "4"
    /// Bytes at the start of a file that are fingerprinted to notice in-place rewrites.
    private static let headLimit = 1024

    /// Seconds since 1970; the day new lines were read counts toward the format-change check.
    private let clock: () -> Double

    static let applicationID: Int32 = 0x5441_524F  // "TARO"

    public init(
        root: URL, databaseURL: URL, opening: IndexOpening = .refuseUnknown,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        clock: @escaping () -> Double = { Date().timeIntervalSince1970 }
    ) throws {
        self.root = TranscriptLocator.canonical(root)
        self.clock = clock
        // One physical path for the check, the folder and the database, so a link cannot redirect what was checked.
        let database = try IndexLocation.physical(databaseURL)
        try IndexLocation.check(database: database, root: root, home: home)
        // Only folders created here are made private; an existing folder someone chose is left as it is.
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        db = try Indexer.open(database, opening)
    }

    // MARK: - Indexing

    /// Scans the whole root: reads new and changed files, newest first, and forgets deleted ones.
    /// A file that cannot be read is reported in `skippedFiles` and does not stop the scan.
    @discardableResult
    public func indexAll(progress: ((IndexProgress) -> Void)? = nil) throws -> IndexSummary {
        var summary = IndexSummary()
        // A first index that was interrupted is still the first: completion is recorded, not inferred from files.
        let isInitial = try !hasCompletedFullIndex()
        let scan = TranscriptLocator.findAll(root: root)
        let present = Set(scan.refs.map(\.url.path))
        for path in try knownPaths() where !present.contains(path) && !scan.isUnderUnreadableDirectory(path) {
            try removeFile(path: path)
            summary.filesRemoved += 1
        }
        let stated = scan.refs.compactMap { ref in FileStat(ref.url).map { (ref, $0) } }
            .sorted { $0.1.modified > $1.1.modified }
        var known: [String: (offset: UInt64, inode: UInt64)] = [:]
        try db.query("SELECT path, offset, inode FROM files") {
            known[$0.text(0)] = (UInt64(bitPattern: Int64($0.int(1))), UInt64(bitPattern: Int64($0.int(2))))
        }
        // Bytes still to read per file: the unread tail, or the whole file when it was replaced or truncated.
        let pending = stated.map { ref, stat -> Int64 in
            guard let row = known[ref.url.path], row.inode == stat.inode, stat.size >= row.offset else {
                return Int64(stat.size)
            }
            return Int64(stat.size - row.offset)
        }
        var report = IndexProgress(bytesRead: 0, bytesTotal: pending.reduce(0, +), isInitial: isInitial)
        var lastReport = ContinuousClock.now
        for ((ref, stat), bytes) in zip(stated, pending) {
            summary.add(try indexSkippingFailures(ref, stat, initial: isInitial))
            report.bytesRead += bytes
            if let progress, ContinuousClock.now - lastReport >= .milliseconds(100) {
                progress(report)
                lastReport = .now
            }
        }
        progress?(report)
        try db.run("DELETE FROM read_stats WHERE day < ?", [.int(Indexer.day(clock()) - 30)])
        try db.run(
            "INSERT OR REPLACE INTO meta(key, value) VALUES('last_full_index_at', ?)", [.text(String(clock()))])
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
                if let stat = FileStat(ref.url) { summary.add(try indexSkippingFailures(ref, stat, initial: false)) }
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
    private func indexSkippingFailures(_ ref: TranscriptRef, _ stat: FileStat, initial: Bool) throws -> IndexSummary {
        do {
            return try index(ref, stat, initial: initial)
        } catch let error as SQLiteError {
            throw error
        } catch {
            return IndexSummary(
                filesScanned: 1, skippedFiles: [SkippedFile(path: ref.url.path, reason: error.localizedDescription)])
        }
    }

    /// `initial`: part of the first index, whose lines are old history rather than new writes (BR-H1).
    private func index(_ ref: TranscriptRef, _ stat: FileStat, initial: Bool) throws -> IndexSummary {
        try db.transaction {
            var summary = IndexSummary(filesScanned: 1)
            var file = try fileRow(path: ref.url.path) ?? insertFile(ref, stat)
            if try file.inode != stat.inode || stat.size < file.offset || headChanged(file, at: ref.url) {
                try resetFile(file)  // R7: replaced, truncated or rewritten in place
                if file.offset > 0 { summary.filesReset = 1 }  // its calls are gone even if nothing new is read
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
            let now = clock()
            // Format-change evidence (BR-H1): assistant lines by their own day, appended lines by today.
            var assistantByDay: [Int: (lines: Int, withoutCall: Int)] = [:]
            var callsAppended = 0
            func countAssistant(at timestamp: Double?, call: Bool) {
                let day = Indexer.day(timestamp ?? now)
                assistantByDay[day, default: (0, 0)].lines += 1
                if !call { assistantByDay[day, default: (0, 0)].withoutCall += 1 }
            }
            let nextOffset = try LineReader.readCompleteLines(at: ref.url, from: file.offset) { line in
                lines += 1
                switch RecordParser.parse(line) {
                case .notCandidate:
                    return
                case .rejected:
                    candidates += 1
                case .assistantWithoutCall(let timestamp):
                    candidates += 1
                    countAssistant(at: timestamp, call: false)
                case .malformed:
                    candidates += 1
                    failures += 1
                    if !initial, line.range(of: Indexer.assistantType) != nil { countAssistant(at: nil, call: false) }
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
                    countAssistant(at: call.timestamp, call: true)
                    switch try recordOccurrence(call, fileID: file.id, seq: seq) {
                    case .inserted:
                        seq += 1
                        callsAppended += 1
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
            for (day, counts) in assistantByDay {
                try addReadStats(fileID: file.id, day: day, assistant: counts)
            }
            if !initial, lines > 0 {
                try addReadStats(fileID: file.id, day: Indexer.day(now), appended: (lines, callsAppended))
            }
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

    /// True when at least one transcript has been indexed: there are earlier results to show.
    /// True once a full scan has finished; an interrupted first index still shows its progress (W1.5).
    public func hasIndexedFiles() throws -> Bool { try hasCompletedFullIndex() }

    private func hasCompletedFullIndex() throws -> Bool {
        try db.queryRow("SELECT COUNT(*) FROM meta WHERE key = 'last_full_index_at'") { $0.int(0) } ?? 0 > 0
    }

    /// Format-change check (2-3 BR-H1): assistant lines over the last seven days, appended lines per day over
    /// the last two days, so one earlier call cannot hide a day of lines without calls.
    public func health(now: Double = Date().timeIntervalSince1970) throws -> IndexHealth {
        let today = Indexer.day(now)
        let since = today - 6
        var health = IndexHealth()
        try db.query(
            "SELECT COALESCE(SUM(assistant_lines), 0), COALESCE(SUM(assistant_without_call), 0) FROM read_stats "
                + "WHERE day >= ?", [.int(since)]
        ) {
            health.assistantLines = $0.int(0)
            health.assistantWithoutCall = $0.int(1)
        }
        var dayWithoutCalls = false
        try db.query(
            """
            SELECT r.day, SUM(r.lines_appended), SUM(r.calls_appended)
            FROM read_stats r JOIN files f ON f.id = r.file_id WHERE f.kind = 'main' AND r.day >= ? GROUP BY r.day
            """, [.int(today - 1)]
        ) {
            health.mainLinesAppended += $0.int(1)
            health.mainCallsAppended += $0.int(2)
            if $0.int(1) >= 200, $0.int(2) == 0 { dayWithoutCalls = true }
        }
        if health.assistantLines >= 50, health.assistantWithoutCall * 20 > health.assistantLines {
            health.kind = .unreadableLines(share: Double(health.assistantWithoutCall) / Double(health.assistantLines))
        } else if dayWithoutCalls {
            health.kind = .noCalls
        }
        return health
    }

    /// The last call in a session's main transcript, with the TTL its cache is under (2-3 BR-I3).
    public func lastCall(ofSession sessionID: String) throws -> LastCall? {
        guard
            let file = try db.queryRow(
                "SELECT id, path FROM files WHERE kind = 'main' AND session_id = ? ORDER BY birthtime DESC LIMIT 1",
                [.text(sessionID)], { (id: $0.int(0), path: $0.text(1)) })
        else { return nil }
        guard
            let call = try db.queryRow(
                """
                SELECT message_id, ts, model, version, line_session_id, input_tokens, output_tokens,
                cache_read_tokens, cache_write_tokens, cache_write_1h, cache_write_5m, ttl, iterations
                FROM occurrences WHERE file_id = ? ORDER BY seq DESC LIMIT 1
                """, [.int(file.id)],
                { s in
                    CallRecord(
                        messageID: s.text(0), timestamp: s.double(1), model: s.text(2), version: s.optionalText(3),
                        lineSessionID: s.optionalText(4), inputTokens: s.int(5), outputTokens: s.int(6),
                        cacheReadTokens: s.int(7), cacheWriteTokens: s.int(8), cacheWrite1h: s.int(9),
                        cacheWrite5m: s.int(10), ttl: s.optionalText(11).flatMap(CacheTTL.init(rawValue:)),
                        iterations: Indexer.decodeIterations(s.optionalText(12)))
                })
        else { return nil }
        // A call without a TTL breakdown is under the last TTL seen in the file, else one hour (2-2 R5).
        let inherited =
            try db.queryRow(
                "SELECT ttl FROM occurrences WHERE file_id = ? AND ttl IS NOT NULL ORDER BY seq DESC LIMIT 1",
                [.int(file.id)]
            ) { CacheTTL(rawValue: $0.text(0)) } ?? nil
        return LastCall(
            sessionID: sessionID, file: URL(fileURLWithPath: file.path), timestamp: call.timestamp,
            ttl: call.ttl ?? inherited ?? .oneHour, model: call.model, contextTokens: call.contextTokens,
            title: try title(of: sessionID))
    }

    /// Main sessions with a call at or after `since`, for when running sessions cannot be read (2-3 BR-E1).
    public func mainSessions(withCallsSince since: Double) throws -> [String] {
        var sessions: [String] = []
        try db.query(
            """
            SELECT DISTINCT f.session_id FROM occurrences o JOIN files f ON f.id = o.file_id
            WHERE f.kind = 'main' AND o.ts >= ? ORDER BY f.session_id
            """, [.double(since)]
        ) { sessions.append($0.text(0)) }
        return sessions
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

    private static func open(_ url: URL, _ opening: IndexOpening) throws -> SQLiteDatabase {
        if opening == .startOver { try removeIndexFiles(at: url) }
        do {
            return try openOwnIndex(url)
        } catch {
            // The index is derived data: at the app's own location, a damaged or unknown file is replaced.
            guard opening != .refuseUnknown, isUnusable(error) else { throw error }
            try removeIndexFiles(at: url)
            return try openOwnIndex(url)
        }
    }

    private static func isUnusable(_ error: Error) -> Bool {
        if case .notAnIndex = error as? IndexOpenError { return true }
        return (error as? SQLiteError)?.isCorruption == true
    }

    /// Removes a regular file and its side files. A folder, link or pipe at the index path is reported instead:
    /// nothing but a file is ever removed.
    private static func removeIndexFiles(at url: URL) throws {
        if let type = fileType(url), type != .typeRegular { throw IndexOpenError.notAnIndex(url.path) }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// The type of the item itself (a link is not followed), or nil when nothing is there.
    private static func fileType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    private static func openOwnIndex(_ url: URL) throws -> SQLiteDatabase {
        // Ownership is settled before anything writes, so a file this app did not make is never changed.
        try checkOwnership(url)
        let db = try SQLiteDatabase(path: url.path, noFollow: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // Schema and marker come before WAL: a new index has them in its main file from the start, so any
        // other connection that reads the file recognizes it.
        let marked = try db.transaction { () -> Bool in
            try db.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            let current = try db.queryRow("SELECT value FROM meta WHERE key = 'schema_version'") { $0.text(0) }
            let rebuilt = current != schemaVersion
            if rebuilt {
                // Rebuilt rather than migrated, in one transaction so another process never sees half of it.
                try db.execute(
                    """
                    DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS calls; DROP TABLE IF EXISTS occurrences;
                    DROP TABLE IF EXISTS marks; DROP TABLE IF EXISTS titles; DROP TABLE IF EXISTS read_stats;
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
                    CREATE TABLE read_stats(
                        file_id INTEGER NOT NULL, day INTEGER NOT NULL, assistant_lines INTEGER NOT NULL DEFAULT 0,
                        assistant_without_call INTEGER NOT NULL DEFAULT 0, lines_appended INTEGER NOT NULL DEFAULT 0,
                        calls_appended INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(file_id, day));
                    """)
                try db.run(
                    "INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)", [.text(schemaVersion)])
            }
            let marker = try db.queryRow("PRAGMA application_id") { $0.int(0) }
            if marker != Int(applicationID) { try db.execute("PRAGMA application_id = \(applicationID)") }
            return rebuilt || marker != Int(applicationID)
        }
        try db.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
        // An index that was already in WAL mode got its marker in the WAL: copy it to the file if nobody is
        // reading, without waiting for readers (an unmarked index is still recognized by its schema).
        if marked { try db.execute("PRAGMA wal_checkpoint(PASSIVE)") }
        return db
    }

    /// The tables and columns only this app's index has, beside `meta.schema_version` = the current version.
    private static let ownSchema: [String: Set<String>] = [
        "meta": ["key", "value"],
        "files": ["path", "kind", "session_id", "inode", "offset", "head_hash", "parse_failures"],
        "calls": ["message_id", "owner_file_id", "cache_write_tokens"],
        "occurrences": ["file_id", "message_id", "seq", "iterations"],
        "read_stats": ["file_id", "day", "assistant_without_call", "calls_appended"],
    ]

    /// Throws `.notAnIndex` unless the path holds nothing (and no side files of some other database), an empty
    /// file, a file marked as this app's index, or an unmarked file with this app's schema (an index made
    /// before the marker existed). Only a regular file is opened, so a pipe never blocks.
    private static func checkOwnership(_ url: URL) throws {
        let sideFiles = ["-wal", "-shm", "-journal"].contains {
            FileManager.default.fileExists(atPath: url.path + $0)
        }
        guard let type = fileType(url) else {
            if sideFiles { throw IndexOpenError.notAnIndex(url.path) }
            return
        }
        guard type == .typeRegular else { throw IndexOpenError.notAnIndex(url.path) }
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return }  // SQLite reports the reason
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 100) ?? Data()
        if header.isEmpty {
            if sideFiles { throw IndexOpenError.notAnIndex(url.path) }
            return
        }
        guard header.count == 100, header.starts(with: Data("SQLite format 3\u{0}".utf8)) else {
            throw IndexOpenError.notAnIndex(url.path)
        }
        let marker = header.dropFirst(68).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        if marker == UInt32(bitPattern: applicationID) { return }
        guard marker == 0, try hasOwnSchema(url) else { throw IndexOpenError.notAnIndex(url.path) }
    }

    /// Reads an unmarked file without locks or side files, so another app's database is not touched.
    private static func hasOwnSchema(_ url: URL) throws -> Bool {
        let probe = try SQLiteDatabase(immutableSnapshotOf: url)
        for (table, columns) in ownSchema {
            var found = Set<String>()
            try probe.query("SELECT name FROM pragma_table_info(?)", [.text(table)]) { found.insert($0.text(0)) }
            guard columns.isSubset(of: found) else { return false }
        }
        return try probe.queryRow("SELECT value FROM meta WHERE key = 'schema_version'") { $0.text(0) }
            == schemaVersion
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
        for table in ["occurrences", "marks", "titles", "read_stats"] {
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

    private static let assistantType = Data(#""type":"assistant""#.utf8)

    /// Days since 1970 in UTC, the unit of `read_stats`.
    static func day(_ timestamp: Double) -> Int { Int((timestamp / 86_400).rounded(.down)) }

    private func addReadStats(
        fileID: Int, day: Int, assistant: (lines: Int, withoutCall: Int) = (0, 0),
        appended: (lines: Int, calls: Int) = (0, 0)
    ) throws {
        try db.run(
            """
            INSERT INTO read_stats(file_id, day, assistant_lines, assistant_without_call, lines_appended, calls_appended)
            VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(file_id, day) DO UPDATE SET
            assistant_lines = assistant_lines + excluded.assistant_lines,
            assistant_without_call = assistant_without_call + excluded.assistant_without_call,
            lines_appended = lines_appended + excluded.lines_appended,
            calls_appended = calls_appended + excluded.calls_appended
            """,
            [
                .int(fileID), .int(day), .int(assistant.lines), .int(assistant.withoutCall), .int(appended.lines),
                .int(appended.calls),
            ])
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
