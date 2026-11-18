import Foundation
import RunningOutCore

/// Developer CLI for RunningOutCore: index, compare against the prototype, watch live updates.
///
/// Exit codes: 0 success, 2 usage, 3 no transcripts folder, 4 index cannot be opened, 1 other errors.

// `watch` streams log lines, so flush each line even when stdout is a pipe.
setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func grouped(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
}

func seconds(since start: ContinuousClock.Instant) -> String {
    let elapsed = ContinuousClock.now - start
    return String(format: "%.2fs", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
}

func report(_ summary: IndexSummary) -> String {
    for skipped in summary.skippedFiles { warn("skipped \(skipped.path): \(skipped.reason)") }
    return "files scanned \(summary.filesScanned), read \(summary.filesRead), removed \(summary.filesRemoved), "
        + "calls added \(grouped(summary.callsAdded)), parse failures \(summary.parseFailures), "
        + "skipped \(summary.skippedFiles.count)"
}

func openService(root: URL, database: URL) -> IndexService {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        fail("No Claude Code transcripts at \(root.path)", code: 3)
    }
    do {
        return try IndexService(root: root, databaseURL: database)
    } catch {
        fail("Cannot open index at \(database.path): \(error)", code: 4)
    }
}

func run(_ command: CLICommand) async throws {
    switch command {
    case .index(let root, let database):
        let service = openService(root: root, database: database)
        let start = ContinuousClock.now
        let summary = try await service.indexAll()
        print("indexed in \(seconds(since: start)): \(report(summary))")

    case .stats(let root, let database, let from, let to):
        let service = openService(root: root, database: database)
        _ = report(try await service.indexAll())
        let totals = try await service.stats(from: from, to: to)
        let style = Date.ISO8601FormatStyle()
        let window =
            "\(style.format(Date(timeIntervalSince1970: from))) .. \(style.format(Date(timeIntervalSince1970: to)))"
        print("window              \(window)")
        print("api calls           \(grouped(totals.calls))")
        print(
            "tokens              input=\(grouped(totals.inputTokens)) output=\(grouped(totals.outputTokens)) "
                + "cache_read=\(grouped(totals.cacheReadTokens)) cache_write=\(grouped(totals.cacheWriteTokens))")
        let mismatches = try await service.usageMismatchCount()
        if mismatches > 0 { warn("calls whose copies disagree on usage: \(mismatches)") }

    case .report(let root, let database, let from, let to, let threshold):
        let service = openService(root: root, database: database)
        _ = report(try await service.indexAll())
        let style = Date.ISO8601FormatStyle()
        let text = ReportText.render(
            try await service.report(from: from, to: to, rebuildThreshold: threshold),
            fromText: style.format(Date(timeIntervalSince1970: from)),
            toText: style.format(Date(timeIntervalSince1970: to)))
        print(text)

    case .health(let root, let database):
        let service = openService(root: root, database: database)
        _ = report(try await service.indexAll())
        let health = try await service.health()
        print(
            "assistant lines (7 days)   \(grouped(health.assistantLines)), not calls \(grouped(health.assistantWithoutCall))"
        )
        print(
            "main lines appended        \(grouped(health.mainLinesAppended)), calls \(grouped(health.mainCallsAppended))"
        )
        print("format change              \(health.kind)")

    case .sessions(let root, let database):
        // Counts and numbers only: session titles stay off the terminal.
        let service = openService(root: root, database: database)
        _ = report(try await service.indexAll())
        let registry = SessionRegistry(directory: SessionRegistry.directory(besideRoot: root))
        let state = registry.load()
        switch state {
        case .unavailable:
            print("running sessions           unavailable")
        case .available(let sessions):
            let idle = sessions.filter { $0.status == .idle }.count
            let busy = sessions.filter { $0.status == .busy }.count
            print("running sessions           \(sessions.count) (idle \(idle), busy \(busy))")
        }
        let now = Date().timeIntervalSince1970
        for warning in try await service.expiryWarnings(registry: state, now: now) {
            print(
                "warning                    \(Int(((warning.expiresAt - now) / 60).rounded(.up))) min left, "
                    + "context \(grouped(warning.contextTokens)), \(ReportText.money(warning.rebuildCost)), "
                    + "ttl \(warning.ttl.rawValue), status \(warning.status)")
        }

    case .watch(let root, let database):
        let service = openService(root: root, database: database)
        // Start watching before the first scan, so changes made during the scan are queued, not lost.
        let watcher = TranscriptWatcher(root: root) { urls in
            let received = Date()
            Task {
                let begin = ContinuousClock.now
                do {
                    let result = try await service.update(paths: urls)
                    guard result.filesRead > 0 || result.filesRemoved > 0 || !result.skippedFiles.isEmpty else {
                        return
                    }
                    // How long after the newest change did the index catch up?
                    let newest = urls.compactMap {
                        try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
                    }.max()
                    let lag = newest.map { String(format: "%.2fs", Date().timeIntervalSince($0)) } ?? "?"
                    print(
                        "\(Date.ISO8601FormatStyle().format(received)) update \(seconds(since: begin)), "
                            + "change→indexed \(lag): \(report(result))")
                } catch {
                    warn("update failed: \(error)")
                }
            }
        }
        try watcher.start()
        let start = ContinuousClock.now
        let summary = try await service.indexAll()
        print("indexed in \(seconds(since: start)): \(report(summary))")
        print("watching \(root.path) — Ctrl-C to stop")
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}

let command: CLICommand
do {
    command = try CLIParser.parse(
        Array(CommandLine.arguments.dropFirst()), home: FileManager.default.homeDirectoryForCurrentUser)
} catch {
    fail(error.message, code: error.exitCode)
}

do {
    try await run(command)
} catch {
    fail("running-out: \(error)", code: 1)
}
