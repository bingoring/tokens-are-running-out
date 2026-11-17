import Foundation
import Testing

@testable import RunningOutCore

private actor PathCollector {
    private(set) var names: Set<String> = []
    func add(_ urls: [URL]) { names.formUnion(urls.map(\.lastPathComponent)) }
}

@Suite("TranscriptWatcher")
struct TranscriptWatcherTests {
    @Test("reports a transcript file that is created and appended to")
    func reportsChangedFile() async throws {
        let dir = try TempDir()
        let root = dir.url.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let collector = PathCollector()
        let watcher = TranscriptWatcher(root: root, latency: 0.1) { urls in
            Task { await collector.add(urls) }
        }
        try watcher.start()
        defer { watcher.stop() }

        let file = try dir.write(Fixture.user(), to: "projects/-p/s1.jsonl")
        try dir.append(Fixture.user("again"), to: file)

        var seen = false
        for _ in 0..<50 where !seen {
            try await Task.sleep(for: .milliseconds(100))
            seen = await collector.names.contains("s1.jsonl")
        }
        #expect(seen)
    }
}
