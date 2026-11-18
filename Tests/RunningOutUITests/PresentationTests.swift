import Foundation
import RunningOutCore
import Testing

@testable import RunningOutUI

@Suite("Presentation")
struct PresentationTests {
    private let en = Locale(identifier: "en_US")
    private let ko = Locale(identifier: "ko_KR")

    private func report(_ costs: [CostBucket: Int]) -> UsageReport {
        var report = UsageReport(from: 0, to: 1)
        report.bucketCosts = costs
        report.totalCost = costs.values.reduce(0, +)
        return report
    }

    @Test("six rows in a fixed order; Other holds three causes and their sum")
    func rows() {
        let rows = Presentation.breakdown(
            report([
                .normalWork: 400, .shortBreakRebuild: 100, .longBreakRebuild: 150, .subagents: 90, .advisor: 200,
                .sessionStartAndCompaction: 50, .modelChangeAndUpdate: 10, .unknown: 0,
            ]))
        #expect(rows.map(\.kind) == [.normalWork, .shortBreak, .longBreak, .subagents, .advisor, .other])
        #expect(rows.last?.cost == 60)
        #expect(rows.last?.children.map(\.kind) == [.sessionStartAndCompaction, .modelChangeAndUpdate, .unknown])
        #expect(rows.first?.share == 0.4)
    }

    @Test("an empty period keeps every row at zero")
    func emptyRows() {
        let rows = Presentation.breakdown(UsageReport(from: 0, to: 1))
        #expect(rows.count == 6)
        #expect(rows.allSatisfy { $0.cost == 0 && $0.share == 0 })
    }

    @Test("shares are whole percents, and a sliver above zero reads <1%")
    func shares() {
        #expect(Presentation.shareText(0.233, locale: en) == "23%")
        #expect(Presentation.shareText(0.004, locale: en) == "<1%")
        #expect(Presentation.shareText(0, locale: en) == "0%")
        #expect(Presentation.shareText(0.005, locale: en) == "1%")
    }

    @Test("the rebuild list shows break rebuilds by default, everything but session start when asked, costliest first")
    func rebuildList() {
        var report = UsageReport(from: 0, to: 1)
        func event(_ id: String, _ cause: RebuildCause, cost: Int, at: Double) -> RebuildEvent {
            RebuildEvent(
                messageID: id, timestamp: at, file: URL(fileURLWithPath: "/p"), sessionID: "s", title: nil, cause: cause,
                previousTimestamp: nil, gapSeconds: nil, previousTTL: .oneHour, previousModel: nil, model: "m",
                previousVersion: nil, version: nil, cacheWriteTokens: 1, cacheWriteCost: cost, reducibleCost: 0)
        }
        report.rebuilds = [
            event("start", .sessionStart, cost: 900, at: 1), event("short", .expiredShortBreak, cost: 100, at: 2),
            event("long", .expiredLongBreak, cost: 300, at: 3), event("compact", .afterCompaction, cost: 200, at: 4),
        ]
        #expect(Presentation.rebuildRows(report, showAll: false).map(\.messageID) == ["long", "short"])
        #expect(Presentation.rebuildRows(report, showAll: true).map(\.messageID) == ["long", "compact", "short"])
    }

    @Test("minutes left round up, and under a minute is zero")
    func minutes() {
        #expect(Presentation.minutesLeft(until: 1_000, now: 1_000 - 480) == 8)
        #expect(Presentation.minutesLeft(until: 1_000, now: 1_000 - 481) == 9)
        #expect(Presentation.minutesLeft(until: 1_000, now: 1_000 - 59) == 0)
    }

    @Test("the menu bar shows the soonest expiry, else today's share, else the icon alone")
    func menuBar() {
        let warning = ExpiryWarning(
            sessionID: "s", title: nil, expiresAt: 1_480, ttl: .oneHour, contextTokens: 1, rebuildCost: 1, model: "m",
            priced: true, statusKnown: true)
        var today = UsageReport(from: 0, to: 1)
        #expect(Presentation.menuBar(warnings: [warning], today: today, now: 1_000) == .expiring(minutes: 8))
        #expect(Presentation.menuBar(warnings: [], today: today, now: 1_000) == .iconOnly)
        #expect(Presentation.menuBar(warnings: [], today: nil, now: 1_000) == .iconOnly)
        today.totalCost = 100
        today.shortBreak.cost = 18
        #expect(Presentation.menuBar(warnings: [], today: today, now: 1_000) == .share(0.18))
    }

    @Test("money is US dollars with two decimals, tokens use the locale's short form")
    func formats() {
        #expect(Presentation.money(5_760_000_000, locale: en) == "$5.76")
        #expect(Presentation.money(5_760_000_000, locale: ko) == "$5.76")
        #expect(Presentation.tokens(720_000, locale: en) == "720K")
        #expect(Presentation.tokens(720_000, locale: ko) == "72만")
        #expect(Presentation.tokens(1_100_000, locale: en) == "1.1M")
    }
}
