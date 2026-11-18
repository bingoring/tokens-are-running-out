import Foundation

public enum RebuildCause: String, Sendable, CaseIterable {
    case sessionStart
    case afterCompaction
    case modelChanged
    case expiredShortBreak
    case expiredLongBreak
    case versionChanged
    case unknown
}

/// An owned call inside the window, with its rebuild verdict and the evidence behind it.
public struct ClassifiedCall: Sendable, Equatable {
    public var call: CallRecord
    public var isRebuild: Bool
    /// Set only for rebuilds in main transcripts.
    public var cause: RebuildCause?
    public var previous: CallRecord?
    public var previousTTL: CacheTTL
}

public enum RebuildClassifier {
    /// R2: a rebuild writes at least this many cache tokens, and more than it read.
    public static let rebuildThreshold = 50_000
    /// A cache that expired after a gap of at most this long counts as a short break.
    public static let shortBreakLimit: Double = 3 * 3600

    /// Judged per step: a later step of the same call can read the new cache back, so the call's totals can
    /// hide a rebuild. An advisor consult runs on its own model and never rebuilds the conversation's cache.
    public static func isRebuild(_ part: UsagePart, threshold: Int = rebuildThreshold) -> Bool {
        part.kind == .message && part.cacheWriteTokens >= threshold && part.cacheWriteTokens > part.cacheReadTokens
    }

    public static func isRebuild(_ call: CallRecord, threshold: Int = rebuildThreshold) -> Bool {
        call.parts.contains { isRebuild($0, threshold: threshold) }
    }

    /// Walks one transcript in file order and classifies its owned calls in `[from, to)`.
    /// Every call, copied or outside the window, still becomes the context for the next one (R3).
    public static func classify(
        _ events: [TimelineEvent], kind: TranscriptKind, from: Double, to: Double, threshold: Int = rebuildThreshold
    ) -> [ClassifiedCall] {
        var result: [ClassifiedCall] = []
        var previous: CallRecord?
        var previousTTL: CacheTTL = kind == .main ? .oneHour : .fiveMinutes  // R5 default
        var compacted = false
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            guard case .call(let call, let owned) = event.kind else {
                compacted = true  // R6
                continue
            }
            if owned, from <= call.timestamp, call.timestamp < to {
                let rebuild = isRebuild(call, threshold: threshold)
                let cause =
                    rebuild && kind == .main
                    ? cause(of: call, previous: previous, previousTTL: previousTTL, compacted: compacted) : nil
                result.append(
                    ClassifiedCall(
                        call: call, isRebuild: rebuild, cause: cause, previous: previous, previousTTL: previousTTL))
            }
            previous = call
            previousTTL = call.ttl ?? previousTTL
            compacted = false
        }
        return result
    }

    /// R4: the first matching cause, in this order.
    static func cause(of call: CallRecord, previous: CallRecord?, previousTTL: CacheTTL, compacted: Bool)
        -> RebuildCause
    {
        guard let previous else { return .sessionStart }
        if compacted { return .afterCompaction }
        if call.model != previous.model { return .modelChanged }
        let gap = call.timestamp - previous.timestamp
        if gap > previousTTL.seconds { return gap <= shortBreakLimit ? .expiredShortBreak : .expiredLongBreak }
        if call.version != previous.version { return .versionChanged }
        return .unknown
    }
}

extension CacheTTL {
    public var seconds: Double {
        switch self {
        case .oneHour: return 3600
        case .fiveMinutes: return 300
        }
    }
}
