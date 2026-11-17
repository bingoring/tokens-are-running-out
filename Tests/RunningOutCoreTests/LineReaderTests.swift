import Foundation
import Testing

@testable import RunningOutCore

@Suite("LineReader")
struct LineReaderTests {
    @Test("reads complete lines and leaves a trailing partial line for later")
    func stopsAfterLastNewline() throws {
        let dir = try TempDir()
        let file = try dir.write("a\nbb\nccc", to: "t.jsonl")

        var lines: [Data] = []
        let next = try LineReader.readCompleteLines(at: file, from: 0) { lines.append($0) }

        #expect(lineStrings(lines) == ["a", "bb"])
        #expect(next == 5)
    }

    @Test("a file without any newline consumes nothing")
    func noNewlineConsumesNothing() throws {
        let dir = try TempDir()
        let file = try dir.write("{\"type\":\"assistant\"", to: "t.jsonl")

        var lines: [Data] = []
        let next = try LineReader.readCompleteLines(at: file, from: 0) { lines.append($0) }

        #expect(lines.isEmpty)
        #expect(next == 0)
    }

    @Test("resumes from a saved offset")
    func resumesFromOffset() throws {
        let dir = try TempDir()
        let file = try dir.write("a\nbb\nccc\n", to: "t.jsonl")

        var lines: [Data] = []
        let next = try LineReader.readCompleteLines(at: file, from: 2) { lines.append($0) }

        #expect(lineStrings(lines) == ["bb", "ccc"])
        #expect(next == 9)
    }

    @Test("joins a line that spans several chunks")
    func joinsAcrossChunks() throws {
        let dir = try TempDir()
        let file = try dir.write("hello world\nx\n", to: "t.jsonl")

        var lines: [Data] = []
        let next = try LineReader.readCompleteLines(at: file, from: 0, chunkSize: 4) { lines.append($0) }

        #expect(lineStrings(lines) == ["hello world", "x"])
        #expect(next == 14)
    }

    @Test("reading at the end of the file returns the same offset")
    func nothingNewAtEnd() throws {
        let dir = try TempDir()
        let file = try dir.write("a\n", to: "t.jsonl")

        var lines: [Data] = []
        let next = try LineReader.readCompleteLines(at: file, from: 2) { lines.append($0) }

        #expect(lines.isEmpty)
        #expect(next == 2)
    }
}
