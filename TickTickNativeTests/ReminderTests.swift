import Foundation
import Testing
@testable import TickTickNative

struct ReminderTests {
    @Test func completionDeletionAndMovedDatesUpdatePlan() {
        let now = ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z")!
        let rule = MacReminder(taskID: "t", projectID: "p", offset: DateComponents(hour: 9))
        var task = TickTask(id: "t", projectId: "p", title: "sample", isAllDay: true, dueDate: "2026-10-23T00:00:00Z")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func plan() -> [ReminderDelivery] { ReminderPlan.deliveries(rules: [rule], tasks: [ListedTask(task: task, projectName: "sample")], now: now, calendar: calendar) }
        #expect(calendar.component(.hour, from: plan()[0].date) == 9)
        task.dueDate = "2026-10-24T00:00:00Z"
        #expect(calendar.component(.day, from: plan()[0].date) == 24)
        task.status = 2
        #expect(plan().isEmpty)
        #expect(ReminderPlan.deliveries(rules: [rule], tasks: [], now: now).isEmpty)
    }

    @Test func recurringAllDayReminderKeepsWallClockAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let task = TickTask(id: "t", projectId: "p", title: "sample", isAllDay: true, dueDate: "2026-03-08T00:00:00-0500")
        let plan = ReminderPlan.deliveries(rules: [MacReminder(taskID: "t", projectID: "p", offset: DateComponents(hour: 9))],
            tasks: [ListedTask(task: task, projectName: "sample")], now: now, calendar: calendar)
        #expect(calendar.component(.hour, from: plan[0].date) == 9)
        #expect(calendar.component(.day, from: plan[0].date) == 8)
    }
}
