import Foundation
import Testing
@testable import TickTickNative

struct TaskDateTests {
    @Test func allDayWireFormatKeepsCalendarDateWhenServerNormalizesUTC() throws {
        for zone in ["Asia/Tokyo", "America/Los_Angeles", "Pacific/Kiritimati", "Pacific/Honolulu"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let selected = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 19))!
            let wire = TaskSchedule.wireDate(selected, allDay: true, calendar: calendar)
            #expect(wire == "2026-10-23T00:00:00+0000")
            let server = ISO8601DateFormatter().string(from: try #require(ISO8601DateFormatter().date(from: wire)))
            let restored = try #require(TaskSchedule(calendar: calendar).date(server, allDay: true))
            #expect(restored == calendar.startOfDay(for: selected))
        }
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return value
    }

    @Test func allDayDateKeepsLocalDayAndTimedRangeKeepsInstants() throws {
        let task = TickTask(id: "t", projectId: "p", title: "sample", isAllDay: true, startDate: "2026-10-23T00:00:00+0900", dueDate: "2026-10-24T00:00:00+0900")
        var dates = try TaskDates(task: task, calendar: calendar)
        let changes = try dates.changes(repeating: false, calendar: calendar)
        #expect(changes["startDate"]?.string?.hasPrefix("2026-10-23T00:00:00") == true)
        #expect(changes["dueDate"]?.string?.hasPrefix("2026-10-24T00:00:00") == true)
        dates.allDay = false
        dates.start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 23, minute: 30))!
        dates.end = dates.start.addingTimeInterval(3600)
        let timed = try dates.changes(repeating: false, calendar: calendar)
        let schedule = TaskSchedule(calendar: calendar)
        #expect(schedule.date(timed["startDate"]!.string!, allDay: false) == dates.start)
        #expect(schedule.date(timed["dueDate"]!.string!, allDay: false) == dates.end)
    }

    @Test func reverseRangeAndUndatedRecurrenceAreRejected() throws {
        var dates = try TaskDates(task: TickTask(id: "t", projectId: "p", title: "sample"))
        dates.hasDate = true
        dates.end = dates.start.addingTimeInterval(-60)
        #expect(throws: TaskDateError.self) { try dates.changes(repeating: false) }
        dates.hasDate = false
        #expect(try dates.changes(repeating: false)["startDate"] == .null)
        #expect(throws: TaskDateError.self) { try dates.changes(repeating: true) }
    }
}
