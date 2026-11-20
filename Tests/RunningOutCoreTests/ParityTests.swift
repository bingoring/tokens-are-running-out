import Foundation
import Testing

@testable import RunningOutCore

/// The report on synthetic transcripts must equal the prototype's output, character for character.
/// `prototype/parity.sh` regenerates the comparison against `prototype/drain.py`; CI runs it too.
/// The fixtures end in `.jsonl.txt` because transcript files may not be committed.
@Suite("Prototype parity")
struct ParityTests {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/parity")

    @Test("the report on the synthetic fixtures matches the prototype's output")
    func syntheticFixtures() throws {
        let dir = try TempDir()
        let projects = fixtures.appendingPathComponent("projects")
        let files = try #require(FileManager.default.enumerator(at: projects, includingPropertiesForKeys: nil))
        var written: [String] = []
        for case let file as URL in files where file.lastPathComponent.hasSuffix(".jsonl.txt") {
            let relative = String(file.path.dropFirst(fixtures.path.count + 1).dropLast(".txt".count))
            try dir.write(String(contentsOf: file, encoding: .utf8), to: relative)
            written.append(relative)
        }
        // A copied call whose sessionId matches both files goes to the file created first. As in parity.sh, the
        // creation times are a minute apart in reverse path order, so a tie broken by path would show.
        for (index, relative) in written.sorted(by: >).enumerated() {
            try dir.setCreationDate(
                Date(timeIntervalSince1970: 1_767_225_600 + Double(index) * 60),
                of: dir.url.appendingPathComponent(relative))
        }
        let indexer = try Indexer(
            root: dir.url.appendingPathComponent("projects"),
            databaseURL: dir.url.appendingPathComponent("index.sqlite"))
        try indexer.indexAll()

        let report = try UsageAnalyzer(indexer: indexer, prices: PriceTable.bundled()).report(
            from: 1_794_268_800, to: 1_794_873_600)
        let text = ReportText.render(report, fromText: "2026-11-10T00:00:00Z", toText: "2026-11-17T00:00:00Z")

        let expected = try String(
            contentsOf: fixtures.appendingPathComponent("expected-report.txt"), encoding: .utf8)
        #expect(text + "\n" == expected)
    }
}
