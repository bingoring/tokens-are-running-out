import Foundation

public enum CostBucket: String, Sendable, CaseIterable {
    case normalWork
    case shortBreakRebuild
    case longBreakRebuild
    case sessionStartAndCompaction
    case subagents
    case advisor
    case modelChangeAndUpdate
    case unknown
}

public struct BreakTotals: Sendable, Equatable {
    public var count = 0
    public var tokens = 0
    /// nano-USD
    public var cost = 0

    public init(count: Int = 0, tokens: Int = 0, cost: Int = 0) {
        self.count = count
        self.tokens = tokens
        self.cost = cost
    }
}

/// Advisor consults inside the calls of a window. Their cost is the `advisor` bucket.
public struct AdvisorTotals: Sendable, Equatable {
    public var calls = 0
    public var inputTokens = 0
    public var outputTokens = 0
    /// nano-USD
    public var cost = 0

    public init(calls: Int = 0, inputTokens: Int = 0, outputTokens: Int = 0, cost: Int = 0) {
        self.calls = calls
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cost = cost
    }
}

/// One main-session rebuild and the evidence for its cause ("분류 근거").
public struct RebuildEvent: Sendable, Equatable {
    public var messageID: String
    public var timestamp: Double
    public var file: URL
    public var sessionID: String
    public var title: String?
    public var cause: RebuildCause
    public var previousTimestamp: Double?
    public var gapSeconds: Double?
    public var previousTTL: CacheTTL
    public var previousModel: String?
    public var model: String
    public var previousVersion: String?
    public var version: String?
    /// What the rebuilding steps wrote.
    public var cacheWriteTokens: Int
    /// nano-USD
    public var cacheWriteCost: Int
    /// nano-USD; non-zero only for short-break expiries
    public var reducibleCost: Int
    /// The context of the call before the rebuild: what was cached when the break began.
    public var previousContextTokens: Int?
    /// False when a model of the call is missing from the price table and the cost is an estimate.
    public var priced: Bool

    public init(
        messageID: String, timestamp: Double, file: URL, sessionID: String, title: String?, cause: RebuildCause,
        previousTimestamp: Double?, gapSeconds: Double?, previousTTL: CacheTTL, previousModel: String?, model: String,
        previousVersion: String?, version: String?, cacheWriteTokens: Int, cacheWriteCost: Int, reducibleCost: Int,
        previousContextTokens: Int? = nil, priced: Bool = true
    ) {
        self.messageID = messageID
        self.timestamp = timestamp
        self.file = file
        self.sessionID = sessionID
        self.title = title
        self.cause = cause
        self.previousTimestamp = previousTimestamp
        self.gapSeconds = gapSeconds
        self.previousTTL = previousTTL
        self.previousModel = previousModel
        self.model = model
        self.previousVersion = previousVersion
        self.version = version
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheWriteCost = cacheWriteCost
        self.reducibleCost = reducibleCost
        self.previousContextTokens = previousContextTokens
        self.priced = priced
    }
}

/// Usage in `[from, to)` broken down by cause. Costs are nano-USD at API list prices.
public struct UsageReport: Sendable, Equatable {
    public var from: Double
    public var to: Double
    public var calls = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWriteTokens = 0
    public var totalCost = 0
    public var bucketCosts: [CostBucket: Int] = Dictionary(uniqueKeysWithValues: CostBucket.allCases.map { ($0, 0) })
    public var rebuildCount = 0
    public var rebuildTokens = 0
    public var subagentRebuildCount = 0
    public var mainRebuildCounts: [RebuildCause: Int] = [:]
    public var shortBreak = BreakTotals()
    public var longBreak = BreakTotals()
    public var reducibleCost = 0
    public var advisor = AdvisorTotals()
    public var rebuilds: [RebuildEvent] = []
    public var unpricedModels: [String: Int] = [:]

    public init(from: Double, to: Double) {
        self.from = from
        self.to = to
    }

    /// The menu bar number: cache-write cost of rebuilds after a break, over all cost (R13).
    public var idleRebuildShare: Double { share(shortBreak.cost |+ longBreak.cost) }

    /// What resuming before the cache expired would have saved, over all cost (R12).
    public var reducibleShare: Double { share(reducibleCost) }

    private func share(_ part: Int) -> Double { totalCost == 0 ? 0 : Double(part) / Double(totalCost) }
}

infix operator |+ : AdditionPrecedence
infix operator |+= : AssignmentPrecedence

extension Int {
    /// Saturating addition: a sum past `Int.max` (or below `Int.min`) stays at the limit instead of trapping.
    static func |+ (lhs: Int, rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs > 0 ? .max : .min
    }

    static func |+= (lhs: inout Int, rhs: Int) {
        lhs = (lhs |+ rhs)
    }
}

public final class UsageAnalyzer {
    private let indexer: Indexer
    private let prices: PriceTable
    private let rebuildThreshold: Int

    public init(indexer: Indexer, prices: PriceTable, rebuildThreshold: Int = RebuildClassifier.rebuildThreshold) {
        self.indexer = indexer
        self.prices = prices
        self.rebuildThreshold = rebuildThreshold
    }

    public func report(from: Double, to: Double) throws -> UsageReport {
        var report = UsageReport(from: from, to: to)
        var titles: [String: String?] = [:]
        for file in try indexer.ownedFiles(from: from, to: to) {
            let classified = RebuildClassifier.classify(
                try indexer.timeline(of: file.url), kind: file.kind, from: from, to: to, threshold: rebuildThreshold)
            for item in classified {
                let call = item.call
                // Each step at its own model (R10). Only the steps that rebuilt go to the rebuild's cause (R8).
                var cost = CallCost(cacheWrite: 0, other: 0, writtenAsRead: 0, known: true)
                var rebuilt = (cost: 0, tokens: 0, asRead: 0)
                var advisorCost = 0
                var unpriced = Set<String>()
                var consulted = false
                // Every sum saturates (`|+=`). New lines keep one call far inside Int64 (`RecordParser.tokenLimit`
                // and `iterationLimit`), but rows an older build indexed are not checked again. Only input worth
                // over about 9.2 billion USD reaches the limit, where the prototype's exact integers part ways.
                for part in call.parts {
                    let model = part.model ?? call.model
                    let partCost = prices.cost(of: part, model: model)
                    if !partCost.known { unpriced.insert(model) }
                    cost.cacheWrite |+= partCost.cacheWrite
                    cost.other |+= partCost.other
                    if part.kind == .advisor {
                        consulted = true
                        report.advisor.inputTokens |+= part.inputTokens
                        report.advisor.outputTokens |+= part.outputTokens
                        report.advisor.cost |+= partCost.total
                        advisorCost |+= partCost.total
                    }
                    if item.isRebuild, RebuildClassifier.isRebuild(part, threshold: rebuildThreshold) {
                        rebuilt.cost |+= partCost.cacheWrite
                        rebuilt.tokens |+= part.cacheWriteTokens
                        rebuilt.asRead |+= partCost.writtenAsRead
                    }
                }
                if consulted { report.advisor.calls += 1 }
                for model in unpriced { report.unpricedModels[model, default: 0] += 1 }
                report.calls += 1
                report.inputTokens |+= call.inputTokens
                report.outputTokens |+= call.outputTokens
                report.cacheReadTokens |+= call.cacheReadTokens
                report.cacheWriteTokens |+= call.cacheWriteTokens
                report.totalCost |+= cost.total
                if item.isRebuild {
                    report.rebuildCount += 1
                    report.rebuildTokens |+= rebuilt.tokens
                }

                // Advisor consults have their own bucket; R7: subagents take the rest of their cost;
                // R8: a rebuild's write goes to its cause.
                report.bucketCosts[.advisor, default: 0] |+= advisorCost
                guard file.kind == .main else {
                    report.bucketCosts[.subagents, default: 0] |+= cost.total - advisorCost
                    if item.isRebuild { report.subagentRebuildCount += 1 }
                    continue
                }
                guard item.isRebuild, let cause = item.cause else {
                    report.bucketCosts[.normalWork, default: 0] |+= cost.total - advisorCost
                    continue
                }
                report.bucketCosts[.normalWork, default: 0] |+= cost.total - rebuilt.cost - advisorCost
                report.bucketCosts[Self.bucket(of: cause), default: 0] |+= rebuilt.cost
                report.mainRebuildCounts[cause, default: 0] += 1
                var reducible = 0
                switch cause {
                case .expiredShortBreak:
                    reducible = rebuilt.cost - rebuilt.asRead
                    report.reducibleCost |+= reducible
                    report.shortBreak.count += 1
                    report.shortBreak.tokens |+= rebuilt.tokens
                    report.shortBreak.cost |+= rebuilt.cost
                case .expiredLongBreak:
                    report.longBreak.count += 1
                    report.longBreak.tokens |+= rebuilt.tokens
                    report.longBreak.cost |+= rebuilt.cost
                default:
                    break
                }
                if titles[file.sessionID] == nil {
                    titles[file.sessionID] = .some(try indexer.title(of: file.sessionID))
                }
                report.rebuilds.append(
                    RebuildEvent(
                        messageID: call.messageID, timestamp: call.timestamp, file: file.url,
                        sessionID: file.sessionID, title: titles[file.sessionID] ?? nil, cause: cause,
                        previousTimestamp: item.previous?.timestamp,
                        gapSeconds: item.previous.map { call.timestamp - $0.timestamp },
                        previousTTL: item.previousTTL, previousModel: item.previous?.model, model: call.model,
                        previousVersion: item.previous?.version, version: call.version,
                        cacheWriteTokens: rebuilt.tokens, cacheWriteCost: rebuilt.cost,
                        reducibleCost: reducible, previousContextTokens: item.previous?.contextTokens,
                        priced: unpriced.isEmpty))
            }
        }
        report.rebuilds.sort { ($0.timestamp, $0.messageID) < ($1.timestamp, $1.messageID) }
        return report
    }

    static func bucket(of cause: RebuildCause) -> CostBucket {
        switch cause {
        case .sessionStart, .afterCompaction: return .sessionStartAndCompaction
        case .modelChanged, .versionChanged: return .modelChangeAndUpdate
        case .expiredShortBreak: return .shortBreakRebuild
        case .expiredLongBreak: return .longBreakRebuild
        case .unknown: return .unknown
        }
    }
}

public enum ReportPeriod: String, Sendable, CaseIterable {
    case last5Hours
    case today
    case last7Days

    /// R14: windows end now; "today" starts at local midnight.
    public func window(now: Date = Date(), calendar: Calendar = .current) -> (from: Double, to: Double) {
        let to = now.timeIntervalSince1970
        switch self {
        case .last5Hours: return (to - 5 * 3600, to)
        case .today: return (calendar.startOfDay(for: now).timeIntervalSince1970, to)
        case .last7Days: return (to - 7 * 24 * 3600, to)
        }
    }
}

/// The developer CLI's text, identical to `prototype/drain.py` for the same window.
public enum ReportText {
    /// Python `${:,.2f}` of nano-USD.
    public static func money(_ nano: Int) -> String {
        let fixed = String(format: "%.2f", Double(nano) / 1e9)
        let parts = fixed.split(separator: ".", maxSplits: 1)
        return "$" + grouped(String(parts[0])) + "." + parts[1]
    }

    /// Python `{:.1%}`, right-aligned to `width` like `{:6.1%}`.
    public static func percent(_ value: Double, width: Int = 0) -> String {
        let text = String(format: "%.1f%%", value * 100)
        return String(repeating: " ", count: max(0, width - text.count)) + text
    }

    /// Python `{:,}`.
    public static func count(_ value: Int) -> String { grouped(String(value)) }

    /// The tokens line of `report` and `stats`. The prototype prints no values when there were no calls.
    public static func tokensLine(calls: Int, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> String {
        let values =
            calls == 0
            ? ""
            : "input=\(count(input)) output=\(count(output)) cache_read=\(count(cacheRead)) "
                + "cache_write=\(count(cacheWrite))"
        return "tokens              " + values
    }

    private static func grouped(_ digits: String) -> String {
        var result = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0, character != "-" { result.append(",") }
            result.append(character)
        }
        return String(result.reversed())
    }

    private static let causeLabels: [(RebuildCause, String)] = [
        (.sessionStart, "session start"), (.afterCompaction, "after compaction"), (.modelChanged, "model changed"),
        (.expiredShortBreak, "expired"), (.expiredLongBreak, "expired"), (.versionChanged, "version changed"),
        (.unknown, "unknown"),
    ]

    private static let bucketLabels: [(CostBucket, String)] = [
        (.normalWork, "normal work"), (.shortBreakRebuild, "rebuild after short break"),
        (.longBreakRebuild, "rebuild after long break"), (.sessionStartAndCompaction, "session start & compaction"),
        (.subagents, "subagents"), (.advisor, "advisor"), (.modelChangeAndUpdate, "model change & update"),
        (.unknown, "unknown"),
    ]

    public static func render(_ report: UsageReport, fromText: String, toText: String) -> String {
        func pad(_ text: String, _ width: Int) -> String {
            text + String(repeating: " ", count: max(0, width - text.count))
        }
        var lines: [String] = []
        lines.append("window              \(fromText) .. \(toText)")
        lines.append("api calls           \(count(report.calls))")
        lines.append(
            tokensLine(
                calls: report.calls, input: report.inputTokens, output: report.outputTokens,
                cacheRead: report.cacheReadTokens, cacheWrite: report.cacheWriteTokens))
        let rebuildShare =
            report.cacheWriteTokens == 0 ? 0 : Double(report.rebuildTokens) / Double(report.cacheWriteTokens)
        lines.append(
            "rebuilds            \(report.rebuildCount) calls, \(count(report.rebuildTokens)) tokens "
                + "(\(percent(rebuildShare)) of cache writes)")
        lines.append("  in subagents      \(report.subagentRebuildCount)")
        var byLabel: [String: Int] = [:]
        for (cause, label) in causeLabels {
            if let n = report.mainRebuildCounts[cause], n > 0 { byLabel[label, default: 0] += n }
        }
        let causes = byLabel.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\($0.key) \($0.value)" }
        lines.append("  in main sessions  \(byLabel.values.reduce(0, +)): " + causes.joined(separator: ", "))
        for (name, totals) in [("short break", report.shortBreak), ("long break", report.longBreak)] {
            lines.append("  expired, \(pad(name, 12)) \(totals.count) calls, \(count(totals.tokens)) tokens")
        }
        lines.append("cost (API list)     \(money(report.totalCost))")
        if report.totalCost != 0 {
            for (bucket, label) in bucketLabels {
                let cost = report.bucketCosts[bucket] ?? 0
                lines.append(
                    "  \(pad(label, 27)) \(percent(Double(cost) / Double(report.totalCost), width: 6))  \(money(cost))")
            }
            let advisor = report.advisor
            if advisor.calls > 0 {
                lines.append(
                    "advisor calls       \(advisor.calls), input=\(count(advisor.inputTokens)) "
                        + "output=\(count(advisor.outputTokens))")
            }
            lines.append("menu bar (idle rebuilds) \(percent(report.idleRebuildShare))")
            lines.append("reducible (short breaks) \(percent(report.reducibleShare))")
        }
        if !report.unpricedModels.isEmpty {
            let models = report.unpricedModels.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }
            lines.append("unpriced models     " + models.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
