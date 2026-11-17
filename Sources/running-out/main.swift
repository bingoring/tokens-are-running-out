import Foundation
import RunningOutCore

/// Developer CLI for RunningOutCore: index, compare against the prototype, watch live updates.

// `watch` streams log lines, so flush each line even when stdout is a pipe.
setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func grouped(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
}

func seconds(since start: ContinuousClock.Instant) -> String {
    let elapsed = ContinuousClock.now - start
    return String(format: "%.2fs", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
}

func describe(_ summary: IndexSummary) -> String {
    "files scanned \(summary.filesScanned), read \(summary.filesRead), removed \(summary.filesRemoved), "
        + "calls added \(grouped(summary.callsAdded)), parse failures \(summary.parseFailures)"
}

func requireRoot(_ root: URL) {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        fail("No Claude Code transcripts at \(root.path)", code: 3)
    }
}

func openService(root: URL, database: URL) -> IndexService {
    requireRoot(root)
    do {
        return try IndexService(root: root, databaseURL: database)
    } catch {
        fail("Cannot open index at \(database.path): \(error)", code: 4)
    }
}

let command: CLICommand
do {
    command = try CLIParser.parse(
        Array(CommandLine.arguments.dropFirst()), home: FileManager.default.homeDirectoryForCurrentUser)
} catch {
    fail(error.message, code: error.exitCode)
}

switch command {
case .index(let root, let database):
    let service = openService(root: root, database: database)
    let start = ContinuousClock.now
    let summary = try await service.indexAll()
    print("indexed in \(seconds(since: start)): \(describe(summary))")

case .stats(let root, let database, let from, let to):
    let service = openService(root: root, database: database)
    _ = try await service.indexAll()
    let totals = try await service.stats(from: from, to: to)
    let window = Date.ISO8601FormatStyle()
    print(
        "window              \(window.format(Date(timeIntervalSince1970: from))) .. \(window.format(Date(timeIntervalSince1970: to)))"
    )
    print("api calls           \(grouped(totals.calls))")
    print(
        "tokens              input=\(grouped(totals.inputTokens)) output=\(grouped(totals.outputTokens)) "
            + "cache_read=\(grouped(totals.cacheReadTokens)) cache_write=\(grouped(totals.cacheWriteTokens))")

case .watch(let root, let database):
    let service = openService(root: root, database: database)
    let start = ContinuousClock.now
    let summary = try await service.indexAll()
    print("indexed in \(seconds(since: start)): \(describe(summary))")
    let watcher = TranscriptWatcher(root: root) { urls in
        let received = Date()
        Task {
            let begin = ContinuousClock.now
            do {
                let result = try await service.update(paths: urls)
                guard result.filesRead > 0 || result.filesRemoved > 0 else { return }
                // How long after the newest change did the index catch up?
                let newest = urls.compactMap {
                    try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
                }.max()
                let lag = newest.map { String(format: "%.2fs", Date().timeIntervalSince($0)) } ?? "?"
                print(
                    "\(Date.ISO8601FormatStyle().format(received)) update \(seconds(since: begin)), "
                        + "change→indexed \(lag): \(describe(result))")
            } catch {
                FileHandle.standardError.write(Data("update failed: \(error)\n".utf8))
            }
        }
    }
    try watcher.start()
    print("watching \(root.path) — Ctrl-C to stop")
    while true { try await Task.sleep(for: .seconds(3600)) }
}
