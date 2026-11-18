import Darwin
import Foundation

/// A running Claude Code session, from `~/.claude/sessions/<pid>.json` (2-3 BR-R1).
public struct RunningSession: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case busy
        case idle
        /// A status this version does not know.
        case other
    }

    public var pid: Int32
    public var sessionID: String
    public var name: String?
    public var status: Status
    /// Seconds since 1970.
    public var statusSince: Double?
    public var cwd: String?
    /// When the process started, seconds since 1970, to tell a reused pid apart (BR-R2).
    public var processStart: Double?

    public init(
        pid: Int32, sessionID: String, name: String?, status: Status, statusSince: Double?, cwd: String?,
        processStart: Double?
    ) {
        self.pid = pid
        self.sessionID = sessionID
        self.name = name
        self.status = status
        self.statusSince = statusSince
        self.cwd = cwd
        self.processStart = processStart
    }
}

public enum RegistryState: Sendable, Equatable {
    case available([RunningSession])
    /// The folder is missing or unreadable, or none of its session files could be read (BR-R4).
    case unavailable
}

/// Reads Claude Code's running-session files. Only `<digits>.json` files are opened: the same folder holds
/// key files that this app must never read (BR-R3). It never writes there.
public struct SessionRegistry {
    public let directory: URL
    private let isAlive: (Int32, Double?) -> Bool
    private let read: (URL) throws -> Data

    public init(
        directory: URL, isAlive: @escaping (Int32, Double?) -> Bool = ProcessProbe.isAlive,
        read: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.directory = directory
        self.isAlive = isAlive
        self.read = read
    }

    public static func defaultDirectory(home: URL) -> URL {
        home.appendingPathComponent(".claude/sessions")
    }

    public func load() -> RegistryState {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return .unavailable
        }
        var candidates = 0
        var sessions: [RunningSession] = []
        for name in names {
            guard name.hasSuffix(".json"), let pid = Int32(name.dropLast(".json".count)), pid > 0 else { continue }
            candidates += 1
            guard let data = try? read(directory.appendingPathComponent(name)), let session = parse(data, pid: pid)
            else { continue }
            sessions.append(session)
        }
        if candidates > 0, sessions.isEmpty { return .unavailable }
        return .available(sessions.filter { isAlive($0.pid, $0.processStart) }.sorted { $0.pid < $1.pid })
    }

    func parse(_ data: Data, pid: Int32) -> RunningSession? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (object["pid"] as? NSNumber)?.int32Value == pid,
            let sessionID = object["sessionId"] as? String, !sessionID.isEmpty,
            let statusText = object["status"] as? String
        else { return nil }
        let status: RunningSession.Status =
            switch statusText {
            case "busy": .busy
            case "idle": .idle
            default: .other
            }
        let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return RunningSession(
            pid: pid, sessionID: sessionID, name: name, status: status,
            statusSince: (object["statusUpdatedAt"] as? NSNumber).map { $0.doubleValue / 1000 },
            cwd: object["cwd"] as? String,
            processStart: (object["procStart"] as? String).flatMap(ProcessProbe.parseStartTime))
    }
}

public enum ProcessProbe {
    /// True when `pid` is a running process and, if `startedAt` is known, it started then (within 2 seconds).
    public static func isAlive(pid: Int32, startedAt: Double?) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let startedAt else { return true }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return true }
        let started = info.kp_proc.p_un.__p_starttime
        let seconds = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        return abs(seconds - startedAt) < 2
    }

    /// Claude Code writes `procStart` like `ps -o lstart` ("Tue Nov 17 12:03:11 2026"), in UTC.
    public static func parseStartTime(_ text: String) -> Double? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let collapsed = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return formatter.date(from: collapsed)?.timeIntervalSince1970
    }
}
