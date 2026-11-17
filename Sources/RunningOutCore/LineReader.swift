import Foundation

/// Reads newline-terminated lines from a transcript file, starting at a byte offset.
public enum LineReader {
    private static let newline = UInt8(ascii: "\n")

    /// Calls `body` for every complete line in `[offset, end of file)` and returns the offset
    /// just past the last newline. A trailing line without a newline is not consumed, because
    /// Claude Code may still be writing it.
    public static func readCompleteLines(
        at url: URL,
        from offset: UInt64,
        chunkSize: Int = 4 << 20,
        _ body: (Data) throws -> Void
    ) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var consumed = offset
        var carry = Data()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            carry.append(chunk)
            guard let lastNewline = carry.lastIndex(of: newline) else { continue }

            var lineStart = carry.startIndex
            while let end = carry[lineStart...lastNewline].firstIndex(of: newline) {
                try body(carry[lineStart..<end])
                lineStart = carry.index(after: end)
                if lineStart > lastNewline { break }
            }
            consumed += UInt64(carry.distance(from: carry.startIndex, to: lineStart))
            carry = Data(carry[lineStart...])
        }
        return consumed
    }
}
