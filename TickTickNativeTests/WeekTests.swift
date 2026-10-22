import Foundation
import Testing
@testable import TickTickNative

struct WeekTests {
    @Test func crossingMonthAndPeriodsAreCountedOnce() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30))!
        func item(_ id: String, _ start: String, _ end: String) -> ListedTask {
            ListedTask(task: TickTask(id: id, projectId: "p", title: "sample", isAllDay: true, startDate: start, dueDate: end), projectName: "sample")
        }
        let spanning = item("span", "2026-10-29T00:00:00+0900", "2026-11-03T00:00:00+0900")
        let last = item("last", "2026-11-05T00:00:00+0900", "2026-11-05T00:00:00+0900")
        let outside = item("outside", "2026-11-06T00:00:00+0900", "2026-11-06T00:00:00+0900")
        let overdue = item("past", "2026-10-29T00:00:00+0900", "2026-10-29T00:00:00+0900")
        let groups = WeekSchedule.groups(tasks: [spanning, spanning, last, outside, overdue], now: now, calendar: calendar)
        #expect(groups.count == 7)
        #expect(groups[0].tasks.map(\.task.id) == ["span"])
        #expect(groups[6].tasks.map(\.task.id) == ["last"])
        #expect(groups.flatMap(\.tasks).count == 2)
        #expect(calendar.component(.month, from: groups[6].date) == 11)
    }
}
