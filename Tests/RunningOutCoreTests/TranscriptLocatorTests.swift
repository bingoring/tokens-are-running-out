import Foundation
import Testing

@testable import RunningOutCore

@Suite("TranscriptLocator")
struct TranscriptLocatorTests {
    private let root = URL(fileURLWithPath: "/tmp/projects")

    @Test("a session file directly under a project folder is a main transcript")
    func mainTranscript() {
        let ref = TranscriptLocator.classify(root.appendingPathComponent("-Users-me-app/abc-123.jsonl"), root: root)
        #expect(ref?.kind == .main)
        #expect(ref?.sessionID == "abc-123")
        #expect(ref?.agentID == nil)
    }

    @Test("an agent file under subagents belongs to its parent session")
    func subagentTranscript() {
        let url = root.appendingPathComponent("-Users-me-app/abc-123/subagents/agent-a7e3.jsonl")
        let ref = TranscriptLocator.classify(url, root: root)
        #expect(ref?.kind == .subagent)
        #expect(ref?.sessionID == "abc-123")
        #expect(ref?.agentID == "a7e3")
    }

    @Test("other files are not transcripts")
    func otherFiles() {
        let others = [
            "-Users-me-app/abc-123/subagents/agent-a7e3.meta.json",
            "-Users-me-app/abc-123/tool-results/out.jsonl",
            "-Users-me-app/memory/notes.md",
            "top-level.jsonl",
        ]
        for path in others {
            #expect(TranscriptLocator.classify(root.appendingPathComponent(path), root: root) == nil, "\(path)")
        }
    }

    @Test("findAll returns every transcript under the root and nothing else")
    func findAll() throws {
        let dir = try TempDir()
        try dir.write(Fixture.user(), to: "projects/-p/s1.jsonl")
        try dir.write(Fixture.user(), to: "projects/-p/s1/subagents/agent-x.jsonl")
        try dir.write("{}", to: "projects/-p/s1/subagents/agent-x.meta.json")
        try dir.write(Fixture.user(), to: "projects/-q/s2.jsonl")

        let refs = try TranscriptLocator.findAll(root: dir.url.appendingPathComponent("projects"))
        let names = refs.map { $0.url.lastPathComponent }.sorted()
        #expect(names == ["agent-x.jsonl", "s1.jsonl", "s2.jsonl"])
    }
}
