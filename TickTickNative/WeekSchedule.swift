import Foundation

nonisolated struct DayTasks: Identifiable, Sendable {
    let date: Date
    var tasks: [ListedTask]
    var id: Date { date }
}

nonisolated enum WeekSchedule {
    static func groups(tasks: [ListedTask], now: Date = .now, calendar: Calendar = .current) -> [DayTasks] {
        let today = calendar.startOfDay(for: now)
        let dates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        guard let limit = calendar.date(byAdding: .day, value: 7, to: today) else { return [] }
        let schedule = TaskSchedule(calendar: calendar)
        var indexed: [Date: [ListedTask]] = [:]
        var seen: Set<String> = []
        for item in tasks where seen.insert(item.id).inserted {
            let task = item.task
            guard task.status == nil || task.status == 0,
                  let firstRaw = task.startDate ?? task.dueDate, let lastRaw = task.dueDate ?? task.startDate,
                  let first = schedule.date(firstRaw, allDay: task.isAllDay == true),
                  let last = schedule.date(lastRaw, allDay: task.isAllDay == true),
                  first <= last, last >= today, first < limit else { continue }
            let date = max(calendar.startOfDay(for: first), today)
            indexed[date, default: []].append(item)
        }
        return dates.map { date in
            DayTasks(date: date, tasks: (indexed[date] ?? []).sorted {
                let comparison = $0.task.title.localizedStandardCompare($1.task.title)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            })
        }
    }
}
