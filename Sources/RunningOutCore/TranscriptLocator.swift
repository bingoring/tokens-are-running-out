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

public enum TranscriptLocator {
    /// Main: `<root>/<project>/<sessionId>.jsonl`.
    /// Subagent: `<root>/<project>/<sessionId>/subagents/agent-<agentId>.jsonl`.
    public static func classify(_ url: URL, root: URL) -> TranscriptRef? {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else { return nil }
        let relative = Array(parts.dropFirst(rootParts.count))
        guard let fileName = relative.last, fileName.hasSuffix(".jsonl") else { return nil }
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

    /// Every transcript under `directory` (the root itself or a folder inside it).
    /// `root` should already be canonical (see `canonical(_:)`).
    public static func findAll(root: URL, under directory: URL? = nil) throws -> [TranscriptRef] {
        let start = directory ?? root
        guard
            let walker = FileManager.default.enumerator(
                at: start, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        var refs: [TranscriptRef] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            if let ref = classify(canonical(url), root: root) { refs.append(ref) }
        }
        return refs
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
