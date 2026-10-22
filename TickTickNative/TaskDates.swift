import Foundation

nonisolated struct TaskDates {
    var hasDate: Bool
    var allDay: Bool
    var start: Date
    var end: Date

    init(task: TickTask, now: Date = .now, calendar: Calendar = .current) throws {
        hasDate = task.startDate != nil || task.dueDate != nil
        allDay = task.isAllDay == true
        let schedule = TaskSchedule(calendar: calendar)
        let first = task.startDate ?? task.dueDate
        let last = task.dueDate ?? task.startDate
        if hasDate {
            guard let first, let last, let start = schedule.date(first, allDay: allDay),
                  let end = schedule.date(last, allDay: allDay) else { throw TickTickError.unsupportedFields }
            self.start = start
            self.end = end
        } else {
            start = now
            end = now
        }
    }

    func changes(repeating: Bool, calendar: Calendar = .current) throws -> [String: JSONValue] {
        guard hasDate else {
            guard !repeating else { throw TaskDateError.recurrenceNeedsDate }
            return ["startDate": .null, "dueDate": .null]
        }
        let start = allDay ? calendar.startOfDay(for: start) : start
        let end = allDay ? calendar.startOfDay(for: end) : end
        guard end >= start else { throw TaskDateError.reversed }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        return ["startDate": .string(formatter.string(from: start)), "dueDate": .string(formatter.string(from: end)),
                "isAllDay": .bool(allDay), "timeZone": .string(calendar.timeZone.identifier)]
    }
}

nonisolated enum TaskDateError: LocalizedError {
    case reversed, recurrenceNeedsDate
    var errorDescription: String? {
        switch self {
        case .reversed: "終了は開始以降に指定してください。"
        case .recurrenceNeedsDate: "繰り返しを解除してから日付なしに変更してください。"
        }
    }
}
