import Foundation

public enum TranscriptKind: String, Sendable, Equatable {
    case main
    case subagent
}

/// A transcript file and what its path says about it.
public struct TranscriptRef: Sendable, Equatable {
    public var url: URL
    public var kind: TranscriptKind
    public var sessionID: String
    public var agentID: String?
}

/// The transcripts found under a folder, plus folders that could not be read. Files under an
/// unreadable folder are unknown, not deleted.
public struct TranscriptScan: Sendable, Equatable {
    public var refs: [TranscriptRef] = []
    public var unreadableDirectories: [String] = []

    func isUnderUnreadableDirectory(_ path: String) -> Bool {
        unreadableDirectories.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

public enum TranscriptLocator {
    /// Main: `<root>/<project>/<sessionId>.jsonl`.
    /// Subagent: `<root>/<project>/<sessionId>/subagents/agent-<agentId>.jsonl`.
    /// Hidden files are never transcripts, matching the folder scan.
    public static func classify(_ url: URL, root: URL) -> TranscriptRef? {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else { return nil }
        let relative = Array(parts.dropFirst(rootParts.count))
        guard let fileName = relative.last, fileName.hasSuffix(".jsonl"), !fileName.hasPrefix(".") else {
            return nil
        }
        let stem = String(fileName.dropLast(".jsonl".count))

        switch relative.count {
        case 2:
            return TranscriptRef(url: url, kind: .main, sessionID: stem, agentID: nil)
        case 4 where relative[2] == "subagents" && stem.hasPrefix("agent-"):
            return TranscriptRef(
                url: url, kind: .subagent, sessionID: relative[1], agentID: String(stem.dropFirst("agent-".count)))
        default:
            return nil
        }
    }

    /// Every transcript file under `directory` (the root itself or a folder inside it).
    /// `root` should already be canonical (see `canonical(_:)`).
    public static func findAll(root: URL, under directory: URL? = nil) -> TranscriptScan {
        let failures = FailureList()
        guard
            let walker = FileManager.default.enumerator(
                at: directory ?? root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles],
                errorHandler: { url, _ in
                    failures.append(canonical(url).path)
                    return true
                })
        else { return TranscriptScan(unreadableDirectories: [canonical(directory ?? root).path]) }

        var scan = TranscriptScan()
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if let ref = classify(canonical(url), root: root) { scan.refs.append(ref) }
        }
        scan.unreadableDirectories = failures.items
        return scan
    }

    /// One spelling per file, so paths from FSEvents, the enumerator and callers compare equal
    /// (for example `/var` and `/private/var`). Works for paths that no longer exist by resolving
    /// the deepest existing ancestor.
    public static func canonical(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missing { resolved.appendPathComponent(component) }
        return resolved
    }
}

/// Collects enumerator errors, which may be reported from inside FileManager.
private final class FailureList: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ path: String) { lock.withLock { paths.append(path) } }
    var items: [String] { lock.withLock { paths } }
}
