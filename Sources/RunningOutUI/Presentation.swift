import Foundation
import RunningOutCore

/// One row of "What used your tokens" (2-3 BR-U1).
public struct BreakdownRow: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case normalWork
        case shortBreak
        case longBreak
        case subagents
        case advisor
        case other
        case sessionStartAndCompaction
        case modelChangeAndUpdate
        case unknown
    }

    public var kind: Kind
    /// nano-USD
    public var cost: Int
    public var share: Double
    /// The three causes inside "Other".
    public var children: [BreakdownRow] = []
    public var id: Kind { kind }
}

/// What the menu bar shows (BR-E8).
public enum MenuBarContent: Equatable, Sendable {
    /// Minutes until the soonest warned cache expires; 0 means under a minute.
    case expiring(minutes: Int)
    case share(Double)
    /// No usage today: the icon alone.
    case iconOnly
}

public enum Presentation {
    public static func breakdown(_ report: UsageReport) -> [BreakdownRow] {
        func row(_ kind: BreakdownRow.Kind, _ cost: Int) -> BreakdownRow {
            BreakdownRow(
                kind: kind, cost: cost, share: report.totalCost == 0 ? 0 : Double(cost) / Double(report.totalCost))
        }
        let cost = { (bucket: CostBucket) in report.bucketCosts[bucket] ?? 0 }
        let children = [
            row(.sessionStartAndCompaction, cost(.sessionStartAndCompaction)),
            row(.modelChangeAndUpdate, cost(.modelChangeAndUpdate)), row(.unknown, cost(.unknown)),
        ]
        // The analyzer stops sums at Int.max (R-1), so this one stops there too instead of trapping.
        let otherCost = children.reduce(0) { sum, child in
            let (total, overflow) = sum.addingReportingOverflow(child.cost)
            return overflow ? Int.max : total
        }
        var other = row(.other, otherCost)
        other.children = children
        return [
            row(.normalWork, cost(.normalWork)), row(.shortBreak, cost(.shortBreakRebuild)),
            row(.longBreak, cost(.longBreakRebuild)), row(.subagents, cost(.subagents)), row(.advisor, cost(.advisor)),
            other,
        ]
    }

    /// Whole percent; under half a percent but above zero reads "<1%" (BR-U2).
    public static func shareText(_ share: Double, locale: Locale = .current) -> String {
        let style = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(0))
            .rounded(rule: .toNearestOrAwayFromZero).locale(locale)
        return share > 0 && share < 0.005 ? "<" + 0.01.formatted(style) : share.formatted(style)
    }

    /// Break rebuilds by default; all causes but session start when asked; costliest first, at most 50 (BR-U4).
    public static func rebuildRows(_ report: UsageReport, showAll: Bool) -> [RebuildEvent] {
        let breaks: Set<RebuildCause> = [.expiredShortBreak, .expiredLongBreak]
        return report.rebuilds
            .filter { $0.cause != .sessionStart && (showAll || breaks.contains($0.cause)) }
            .sorted { ($0.cacheWriteCost, $0.timestamp) > ($1.cacheWriteCost, $1.timestamp) }
            .prefix(50).map { $0 }
    }

    /// Whole minutes left, rounded up; 0 when under a minute (BR-E7).
    public static func minutesLeft(until expiresAt: Double, now: Double) -> Int {
        let seconds = expiresAt - now
        return seconds < 60 ? 0 : Int((seconds / 60).rounded(.up))
    }

    /// The "compact before you leave" hint goes under the first warning's advice, when that session is idle and
    /// large (2-5 BR-C14).
    public static func showsCompactHint(_ warning: ExpiryWarning, isFirst: Bool) -> Bool {
        isFirst && warning.status == .idle && warning.contextTokens >= LargeSessionFinder.defaultThresholdTokens
    }

    /// A large session's context and what each call re-reads at the list price (2-5 BR-C6, BR-C7).
    public static func largeSessionDetail(_ session: LargeSession, locale: Locale = .current) -> String {
        let tokens = tokens(session.contextTokens, locale: locale)
        let cost = money(session.readCost, locale: locale)
        return session.priced
            ? String(localized: "Context \(tokens) · re-reads about \(cost) per call", bundle: .module, locale: locale)
            : String(
                localized: "Context \(tokens) · re-reads an estimated \(cost) per call", bundle: .module, locale: locale
            )
    }

    /// Warnings whose cache has not expired yet; a warning disappears the moment its cache expires.
    public static func activeWarnings(_ warnings: [ExpiryWarning], now: Double) -> [ExpiryWarning] {
        warnings.filter { $0.expiresAt > now }
    }

    public static func menuBar(warnings: [ExpiryWarning], today: UsageReport?, now: Double) -> MenuBarContent {
        if let first = activeWarnings(warnings, now: now).first {
            return .expiring(minutes: minutesLeft(until: first.expiresAt, now: now))
        }
        guard let today, today.totalCost != 0 else { return .iconOnly }
        return .share(today.idleRebuildShare)
    }

    /// nano-USD as US dollars with two decimals ("$5.76" in every locale).
    public static func money(_ nano: Int, locale: Locale = .current) -> String {
        (Decimal(nano) / 1_000_000_000).formatted(
            .currency(code: "USD").presentation(.narrow).precision(.fractionLength(2)).locale(locale))
    }

    /// Token counts in the locale's short form: "720K", "72만".
    public static func tokens(_ count: Int, locale: Locale = .current) -> String {
        count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)).locale(locale))
    }
}
