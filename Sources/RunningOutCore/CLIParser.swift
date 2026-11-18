import Foundation

public enum CLICommand: Equatable, Sendable {
    case index(root: URL, database: URL)
    case stats(root: URL, database: URL, from: Double, to: Double)
    case watch(root: URL, database: URL)
    case report(root: URL, database: URL, from: Double, to: Double)
}

public struct CLIError: Error, Equatable {
    public let message: String
    public let exitCode: Int32

    static func usage(_ message: String) -> CLIError {
        CLIError(message: message + "\n" + CLIParser.usage, exitCode: 2)
    }
}

public enum CLIParser {
    public static let usage = """
        usage: running-out index [--root PATH] [--db PATH]
               running-out stats --from ISO8601 --to ISO8601 [--root PATH] [--db PATH]
               running-out report --from ISO8601 --to ISO8601 [--root PATH] [--db PATH]
               running-out watch [--root PATH] [--db PATH]
        """

    public static func defaultRoot(home: URL) -> URL {
        home.appendingPathComponent(".claude/projects")
    }

    public static func defaultDatabase(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/TokensAreRunningOut/index.sqlite")
    }

    public static func parse(_ arguments: [String], home: URL) throws(CLIError) -> CLICommand {
        guard let command = arguments.first, !command.isEmpty else { throw .usage("Missing command.") }

        var options: [String: String] = [:]
        var rest = arguments.dropFirst()
        while let flag = rest.popFirst() {
            guard ["--root", "--db", "--from", "--to"].contains(flag) else { throw .usage("Unknown option \(flag).") }
            guard let value = rest.popFirst() else { throw .usage("Missing value for \(flag).") }
            options[flag] = value
        }
        let root = options["--root"].map { URL(fileURLWithPath: $0) } ?? defaultRoot(home: home)
        let database = options["--db"].map { URL(fileURLWithPath: $0) } ?? defaultDatabase(home: home)
        // R9: the tool never writes into Claude Code's folder or the folder it reads.
        let databasePath = database.standardizedFileURL.path
        for forbidden in [home.appendingPathComponent(".claude"), root] {
            let folder = forbidden.standardizedFileURL.path
            if databasePath == folder || databasePath.hasPrefix(folder + "/") {
                throw .usage("The index cannot live inside \(folder); it must stay read-only.")
            }
        }

        switch command {
        case "index":
            return .index(root: root, database: database)
        case "watch":
            return .watch(root: root, database: database)
        case "stats", "report":
            guard let fromText = options["--from"], let toText = options["--to"] else {
                throw .usage("\(command) needs --from and --to.")
            }
            guard let from = strictUTC(fromText), let to = strictUTC(toText) else {
                throw .usage("Use ISO 8601 UTC, e.g. 2026-11-10T00:00:00Z.")
            }
            guard from < to else { throw .usage("--from must be earlier than --to.") }
            return command == "stats"
                ? .stats(root: root, database: database, from: from, to: to)
                : .report(root: root, database: database, from: from, to: to)
        default:
            throw .usage("Unknown command \(command).")
        }
    }

    /// Accepts only full UTC timestamps in whole seconds, such as `2026-11-10T00:00:00Z`, so the window
    /// printed back is exactly the window given.
    private static func strictUTC(_ text: String) -> Double? {
        guard text.wholeMatch(of: #/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/#) != nil else { return nil }
        return Timestamp.parse(text)
    }
}
