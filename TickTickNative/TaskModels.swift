import Foundation

nonisolated struct TickProject: Codable, Sendable {
    let id: String
    let name: String
    var closed: Bool? = nil
    var permission: String? = nil
    var kind: String? = nil
    var isWritable: Bool { permission == nil || permission == "write" }
}

nonisolated struct TickTask: Codable, Sendable {
    let id: String
    let projectId: String
    let title: String
    var status: Int? = nil
    var isAllDay: Bool? = nil
    var startDate: String? = nil
    var dueDate: String? = nil
    var repeatFlag: String? = nil
}

nonisolated struct ProjectData: Decodable, Sendable {
    let tasks: [TickTask]
}

nonisolated struct ListedTask: Identifiable, Sendable {
    let task: TickTask
    let projectName: String
    var id: String { task.projectId + "/" + task.id }
}

nonisolated struct TaskSnapshot: Sendable {
    var tasks: [ListedTask] = []
    var warnings: [String] = []
    var projectCount = 0
    var projects: [TickProject] = []
}

nonisolated enum DayBucket: Equatable {
    case today, overdue, other, unscheduled, invalidDate
}

nonisolated struct TaskSchedule {
    static func wireDate(_ date: Date, allDay: Bool, calendar: Calendar = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        if allDay {
            formatter.formatOptions = [.withFullDate]
            return formatter.string(from: date) + "T00:00:00+0000"
        }
        return formatter.string(from: date)
    }

    private let calendar: Calendar
    private let standard = ISO8601DateFormatter()
    private let fractional = ISO8601DateFormatter()

    init(calendar: Calendar) {
        self.calendar = calendar
        standard.formatOptions = [.withInternetDateTime]
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func date(_ raw: String, allDay: Bool) -> Date? {
        if allDay {
            let parts = raw.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
                  let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            let components = DateComponents(year: year, month: month, day: day)
            guard let date = gregorian.date(from: components),
                  gregorian.dateComponents([.year, .month, .day], from: date) == components else { return nil }
            return date
        }
        return fractional.date(from: raw) ?? standard.date(from: raw)
    }

    func bucket(_ task: TickTask, now: Date) -> DayBucket {
        guard task.status == nil || task.status == 0 else { return .other }
        let allDay = task.isAllDay == true
        let start = task.startDate.flatMap { date($0, allDay: allDay) }
        let due = task.dueDate.flatMap { date($0, allDay: allDay) }
        if (task.startDate != nil && start == nil) || (task.dueDate != nil && due == nil) {
            return .invalidDate
        }
        guard let first = start ?? due, let last = due ?? start else { return .unscheduled }
        guard first <= last else { return .invalidDate }
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return .invalidDate
        }
        if last < today { return .overdue }
        if first < tomorrow && last >= today { return .today }
        return .other
    }
}
