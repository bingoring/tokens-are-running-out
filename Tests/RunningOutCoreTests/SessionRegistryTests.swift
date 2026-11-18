import Foundation
import Testing

@testable import RunningOutCore

/// Running-session files are synthetic, written into a temporary folder shaped like `~/.claude/sessions`.
@Suite("SessionRegistry")
struct SessionRegistryTests {
    private func session(
        pid: Int, id: String, status: String = "idle", name: String? = "Refactor parser",
        procStart: String? = "Tue Nov 17 12:03:11 2026"
    ) -> String {
        var fields = [
            #""pid":\#(pid)"#, #""sessionId":"\#(id)""#, #""status":"\#(status)""#, #""statusUpdatedAt":1794268800000"#,
            #""cwd":"/work/parser""#, #""kind":"interactive""#,
        ]
        if let name { fields.append(#""name":"\#(name)""#) }
        if let procStart { fields.append(#""procStart":"\#(procStart)""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    @Test("only <pid>.json files are read, and key files beside them are never opened")
    func readsOnlySessionFiles() throws {
        let dir = try TempDir()
        try dir.write(session(pid: 101, id: "s1"), to: "sessions/101.json")
        try dir.write("secret", to: "sessions/101.0123abcd.key")
        try dir.write(session(pid: 102, id: "s2"), to: "sessions/notes.json")
        var opened: [String] = []
        let registry = SessionRegistry(
            directory: dir.url.appendingPathComponent("sessions"), isAlive: { _, _ in true },
            read: { url in
                opened.append(url.lastPathComponent)
                return try Data(contentsOf: url)
            })
        guard case .available(let sessions) = registry.load() else {
            Issue.record("expected available")
            return
        }
        #expect(sessions.map(\.sessionID) == ["s1"])
        #expect(opened == ["101.json"])
    }

    @Test("a session file becomes a running session with its status, name and times")
    func parsesSession() throws {
        let dir = try TempDir()
        try dir.write(session(pid: 101, id: "s1", status: "idle"), to: "sessions/101.json")
        try dir.write(session(pid: 102, id: "s2", status: "busy", name: nil), to: "sessions/102.json")
        try dir.write(session(pid: 103, id: "s3", status: "waiting"), to: "sessions/103.json")
        try dir.write(session(pid: 104, id: "s4", status: "thinking"), to: "sessions/104.json")
        let registry = SessionRegistry(directory: dir.url.appendingPathComponent("sessions"), isAlive: { _, _ in true })
        guard case .available(let sessions) = registry.load() else {
            Issue.record("expected available")
            return
        }
        #expect(sessions.map(\.status) == [.idle, .busy, .waiting, .other])
        #expect(sessions[0].name == "Refactor parser")
        #expect(sessions[1].name == nil)
        #expect(sessions[0].statusSince == 1_794_268_800)
        #expect(sessions[0].cwd == "/work/parser")
        // procStart is the process start in `ps lstart` form, in UTC.
        #expect(sessions[0].processStart == 1_794_916_991)
    }

    @Test("a file whose pid differs from its name, or that is not valid JSON, is skipped")
    func skipsBadFiles() throws {
        let dir = try TempDir()
        try dir.write(session(pid: 101, id: "s1"), to: "sessions/101.json")
        try dir.write(session(pid: 999, id: "s2"), to: "sessions/102.json")
        try dir.write("{not json", to: "sessions/103.json")
        let registry = SessionRegistry(directory: dir.url.appendingPathComponent("sessions"), isAlive: { _, _ in true })
        #expect(
            registry.load()
                == .available([try #require(registry.parse(Data(session(pid: 101, id: "s1").utf8), pid: 101))]))
    }

    @Test("sessions whose process is gone are left out")
    func deadProcessesLeftOut() throws {
        let dir = try TempDir()
        try dir.write(session(pid: 101, id: "s1"), to: "sessions/101.json")
        try dir.write(session(pid: 102, id: "s2"), to: "sessions/102.json")
        let registry = SessionRegistry(
            directory: dir.url.appendingPathComponent("sessions"), isAlive: { pid, _ in pid == 102 })
        guard case .available(let sessions) = registry.load() else {
            Issue.record("expected available")
            return
        }
        #expect(sessions.map(\.sessionID) == ["s2"])
    }

    @Test("a missing folder, or session files none of which can be read, make the registry unavailable")
    func unavailable() throws {
        let dir = try TempDir()
        let missing = SessionRegistry(directory: dir.url.appendingPathComponent("sessions"), isAlive: { _, _ in true })
        #expect(missing.load() == .unavailable)
        try dir.write(#"{"processId":1}"#, to: "sessions/101.json")
        #expect(missing.load() == .unavailable)
        try FileManager.default.removeItem(at: dir.url.appendingPathComponent("sessions/101.json"))
        #expect(missing.load() == .available([]))
    }

    @Test("ps-style start times parse in UTC, with or without a padded day")
    func startTimes() {
        #expect(ProcessProbe.parseStartTime("Tue Nov 17 12:03:11 2026") == 1_794_916_991)
        #expect(ProcessProbe.parseStartTime("Sat Nov  7 12:03:11 2026") == 1_794_052_991)
        #expect(ProcessProbe.parseStartTime("2026-11-17T12:03:11Z") == nil)
    }

    @Test("the process probe sees this test process as alive, and a reused pid as gone")
    func probe() {
        let pid = getpid()
        #expect(ProcessProbe.isAlive(pid: pid, startedAt: nil))
        #expect(!ProcessProbe.isAlive(pid: pid, startedAt: 1_000_000_000))
    }

    @Test("a start time written in UTC or in local time both match the running process")
    func startTimeInEitherZone() throws {
        // `ps -o lstart` prints this process's start in local time, in the same shape as `procStart`.
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "lstart=", "-p", String(getpid())]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        ps.waitUntilExit()
        let local = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedAsUTC = try #require(ProcessProbe.parseStartTime(local))
        #expect(ProcessProbe.isAlive(pid: getpid(), startedAt: parsedAsUTC))
        // The same instant written in UTC, as Claude Code writes it.
        let offset = Double(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: parsedAsUTC)))
        #expect(ProcessProbe.isAlive(pid: getpid(), startedAt: parsedAsUTC - offset))
    }

    @Test("the sessions folder sits beside the transcripts root")
    func folderBesideRoot() {
        #expect(
            SessionRegistry.directory(besideRoot: URL(fileURLWithPath: "/u/.claude/projects"))
                == URL(fileURLWithPath: "/u/.claude/sessions"))
    }
}
