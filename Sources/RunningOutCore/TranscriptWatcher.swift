import CoreServices
import Foundation

/// Watches the transcript root with FSEvents and reports changed paths in batches.
///
/// `start()` and `stop()` must be called from one thread; the handler runs on a private queue.
/// When FSEvents drops events (`MustScanSubDirs`), the handler receives the root so the caller
/// rescans everything.
public final class TranscriptWatcher: @unchecked Sendable {
    private let root: URL
    private let latency: TimeInterval
    private let handler: @Sendable ([URL]) -> Void
    private let queue = DispatchQueue(label: "TokensAreRunningOut.TranscriptWatcher")
    private var stream: FSEventStreamRef?

    public init(root: URL, latency: TimeInterval = 0.5, handler: @escaping @Sendable ([URL]) -> Void) {
        self.root = TranscriptLocator.canonical(root)
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard
            let stream = FSEventStreamCreate(
                nil, TranscriptWatcher.callback, &context, [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { throw WatcherError.cannotCreateStream }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw WatcherError.cannotStart
        }
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func deliver(paths: [String], flags: [FSEventStreamEventFlags]) {
        let mustRescan = flags.contains { $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
        if mustRescan {
            handler([root])
            return
        }
        var unique: [String] = []
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted { unique.append(path) }
        handler(unique.map { URL(fileURLWithPath: $0) })
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
        watcher.deliver(paths: list, flags: flagList)
    }
}

public enum WatcherError: Error {
    case cannotCreateStream
    case cannotStart
}
