import Foundation

/// A temporary directory that is removed when the value is deinitialized.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("running-out-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes `text` to `relativePath`, creating intermediate directories.
    @discardableResult
    func write(_ text: String, to relativePath: String) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    /// Appends `text` to an existing file without replacing it (keeps the inode).
    func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Sets the file's creation date, which the index uses to pick an owner file.
    func setCreationDate(_ date: Date, of file: URL) throws {
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: file.path)
    }
}

func lineStrings(_ lines: [Data]) -> [String] {
    lines.map { String(decoding: $0, as: UTF8.self) }
}
