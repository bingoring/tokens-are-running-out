import Foundation
import Testing

@testable import RunningOutCore

@Suite("ReportPeriod")
struct ReportPeriodTests {
    // 2026-11-17T09:30:00Z is 18:30 in Seoul (UTC+9). Epoch values derived independently.
    private let now = Date(timeIntervalSince1970: 1_794_907_800)

    private var seoul: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    @Test("today starts at local midnight")
    func today() {
        let window = ReportPeriod.today.window(now: now, calendar: seoul)
        #expect(window.from == 1_794_841_200)  // 2026-11-17T00:00 KST = 2026-11-16T15:00:00Z
        #expect(window.to == 1_794_907_800)
    }

    @Test("the last five hours and the last seven days end now")
    func rolling() {
        #expect(ReportPeriod.last5Hours.window(now: now, calendar: seoul).from == 1_794_889_800)
        #expect(ReportPeriod.last7Days.window(now: now, calendar: seoul).from == 1_794_303_000)
    }
}
