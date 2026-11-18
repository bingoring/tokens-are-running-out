import Foundation
import Testing

@testable import RunningOutCore

@Suite("CLIParser")
struct CLIParserTests {
    private let home = URL(fileURLWithPath: "/Users/someone")

    private func parse(_ arguments: String) throws(CLIError) -> CLICommand {
        try CLIParser.parse(arguments.split(separator: " ").map(String.init), home: home)
    }

    private func exitCode(_ arguments: String) -> Int32? {
        do {
            _ = try parse(arguments)
            return nil
        } catch {
            return error.exitCode
        }
    }

    @Test("index uses the Claude Code projects folder and the app's index by default")
    func defaults() throws {
        let command = try parse("index")
        #expect(
            command
                == .index(
                    root: URL(fileURLWithPath: "/Users/someone/.claude/projects"),
                    database: URL(
                        fileURLWithPath: "/Users/someone/Library/Application Support/TokensAreRunningOut/index.sqlite")
                ))
    }

    @Test("stats reads its window and paths from options")
    func statsOptions() throws {
        let command = try parse("stats --root /r --db /d.sqlite --from 2026-11-10T00:00:00Z --to 2026-11-17T00:00:00Z")
        #expect(
            command
                == .stats(
                    root: URL(fileURLWithPath: "/r"), database: URL(fileURLWithPath: "/d.sqlite"),
                    from: 1_794_268_800, to: 1_794_873_600))
    }

    @Test("stats without a window, with a bad date, or with an empty window is a usage error")
    func statsErrors() {
        #expect(exitCode("stats --from 2026-11-10T00:00:00Z") == 2)
        #expect(exitCode("stats --from 2026-11-10 --to 2026-11-17T00:00:00Z") == 2)
        #expect(exitCode("stats --from 2026-11-17T00:00:00Z --to 2026-11-10T00:00:00Z") == 2)
        #expect(exitCode("stats --from 2026-11-10T00:00:00Z --to 2026-11-10T00:00:00Z") == 2)
    }

    @Test("unknown commands, unknown options and missing option values are usage errors")
    func usageErrors() {
        #expect(exitCode("") == 2)
        #expect(exitCode("report") == 2)
        #expect(exitCode("index --verbose") == 2)
        #expect(exitCode("index --root") == 2)
    }

    @Test("an index path inside ~/.claude or inside the root is refused (read-only rule R9)")
    func databaseInsideClaudeRefused() {
        #expect(exitCode("index --db /Users/someone/.claude/index.sqlite") == 2)
        #expect(exitCode("index --root /r --db /r/sub/index.sqlite") == 2)
        #expect(exitCode("index --root /r --db /rr/index.sqlite") == nil)
    }

    @Test("report takes a window like stats")
    func report() throws {
        let command = try parse("report --root /r --db /d.sqlite --from 2026-11-10T00:00:00Z --to 2026-11-17T00:00:00Z")
        #expect(
            command
                == .report(
                    root: URL(fileURLWithPath: "/r"), database: URL(fileURLWithPath: "/d.sqlite"),
                    from: 1_794_268_800, to: 1_794_873_600, rebuildThreshold: 50_000))
        #expect(exitCode("report --from 2026-11-10T00:00:00Z") == 2)
    }

    @Test("report takes a rebuild threshold of one token or more")
    func reportThreshold() throws {
        let window = "--root /r --db /d.sqlite --from 2026-11-10T00:00:00Z --to 2026-11-17T00:00:00Z"
        #expect(
            try parse("report \(window) --rebuild-threshold 30000")
                == .report(
                    root: URL(fileURLWithPath: "/r"), database: URL(fileURLWithPath: "/d.sqlite"),
                    from: 1_794_268_800, to: 1_794_873_600, rebuildThreshold: 30_000))
        #expect(exitCode("report \(window) --rebuild-threshold 0") == 2)
        #expect(exitCode("report \(window) --rebuild-threshold lots") == 2)
    }

    @Test("a window boundary with fractional seconds is refused, so the printed window is exact")
    func wholeSecondsOnly() {
        #expect(exitCode("report --from 2026-11-10T00:00:00.5Z --to 2026-11-17T00:00:00Z") == 2)
        #expect(exitCode("stats --from 2026-11-10T00:00:00Z --to 2026-11-17T00:00:00.000Z") == 2)
    }

    @Test("watch accepts the same path options as index")
    func watch() throws {
        #expect(
            try parse("watch --root /r --db /d.sqlite")
                == .watch(root: URL(fileURLWithPath: "/r"), database: URL(fileURLWithPath: "/d.sqlite")))
    }

    @Test("health takes the same path options as index")
    func health() throws {
        #expect(
            try parse("health --root /r --db /d.sqlite")
                == .health(root: URL(fileURLWithPath: "/r"), database: URL(fileURLWithPath: "/d.sqlite")))
    }

    @Test("sessions takes the same path options as index")
    func sessions() throws {
        #expect(
            try parse("sessions --root /r --db /d.sqlite")
                == .sessions(root: URL(fileURLWithPath: "/r"), database: URL(fileURLWithPath: "/d.sqlite")))
    }
}
