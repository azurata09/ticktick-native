import Foundation
import UserNotifications

nonisolated struct MacReminder: Codable, Sendable {
    let taskID: String
    let projectID: String
    let offset: DateComponents
    var id: String { projectID + "/" + taskID }
}

nonisolated struct ReminderDelivery: Sendable {
    let id: String
    let title: String
    let date: Date
}

nonisolated enum ReminderPlan {
    private static var wallCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func wallDate(_ date: Date, calendar: Calendar) -> Date {
        wallCalendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date))!
    }

    static func offset(from start: Date, to date: Date, calendar: Calendar = .current) -> DateComponents {
        wallCalendar.dateComponents([.day, .hour, .minute, .second], from: wallDate(start, calendar: calendar), to: wallDate(date, calendar: calendar))
    }

    static func date(start: Date, offset: DateComponents, calendar: Calendar) -> Date? {
        guard let wall = wallCalendar.date(byAdding: offset, to: wallDate(start, calendar: calendar)) else { return nil }
        return calendar.date(from: wallCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wall))
    }

    static func deliveries(rules: [MacReminder], tasks: [ListedTask], now: Date = .now, calendar: Calendar = .current) -> [ReminderDelivery] {
        let schedule = TaskSchedule(calendar: calendar)
        let indexed = Dictionary(tasks.map { ($0.id, $0.task) }, uniquingKeysWith: { first, _ in first })
        return rules.compactMap { rule in
            guard let task = indexed[rule.id], task.status != 2, task.status != -1,
                  let raw = task.startDate ?? task.dueDate,
                  let start = schedule.date(raw, allDay: task.isAllDay == true) else { return nil }
            guard let date = date(start: start, offset: rule.offset, calendar: calendar), date > now else { return nil }
            return ReminderDelivery(id: rule.id, title: task.title, date: date)
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
}

@MainActor
final class MacReminders: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let journal = FileJournal<[MacReminder]>(filename: "mac-reminders.json")
    private var rules: [MacReminder] = []
    private var loaded = false
    private var revision = UUID()

    override init() {
        super.init()
        center.delegate = self
    }

    private func load() throws {
        guard !loaded else { return }
        rules = try journal.load() ?? []
        loaded = true
    }

    func set(task: TickTask, date: Date?, now: Date = .now) async throws {
        try load()
        let id = task.projectId + "/" + task.id
        var updated = rules.filter { $0.id != id }
        if let date {
            guard date > now, let raw = task.startDate ?? task.dueDate,
                  let start = TaskSchedule(calendar: .current).date(raw, allDay: task.isAllDay == true) else { throw ReminderError.invalidDate }
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { throw ReminderError.denied }
            updated.append(MacReminder(taskID: task.id, projectID: task.projectId, offset: ReminderPlan.offset(from: start, to: date)))
        }
        try journal.save(updated)
        rules = updated
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func synchronize(snapshot: TaskSnapshot) async throws -> String? {
        try load()
        let current = revision
        let projects = Set(snapshot.projects.map(\.id))
        let taskIDs = Set(snapshot.tasks.map(\.id))
        // 取得に失敗したリストの通知は、削除されたと判断しない。
        let removed = rules.filter { projects.contains($0.projectID) && !taskIDs.contains($0.id) }.map(\.id)
        let pending = await center.pendingNotificationRequests()
        guard current == revision else { return nil }
        let known = Set(rules.map(\.id))
        if !removed.isEmpty {
            let remaining = rules.filter { !removed.contains($0.id) }
            try journal.save(remaining)
            rules = remaining
        }
        let deliveries = ReminderPlan.deliveries(rules: rules, tasks: snapshot.tasks)
        let scheduled = Array(deliveries.prefix(60))
        let wanted = Set(scheduled.map(\.id))
        let cancel = pending.map(\.identifier).filter { id in
            known.contains(id) && (removed.contains(id) || (taskIDs.contains(id) && !wanted.contains(id)))
        }
        center.removePendingNotificationRequests(withIdentifiers: cancel)
        center.removeDeliveredNotifications(withIdentifiers: cancel + removed)
        guard !scheduled.isEmpty else { return nil }
        let settings = await center.notificationSettings()
        guard current == revision else { return nil }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { throw ReminderError.denied }
        for delivery in scheduled {
            guard current == revision else { return nil }
            let content = UNMutableNotificationContent()
            content.title = delivery.title
            content.body = "TickTick Nativeの作業予定"
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: delivery.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try await center.add(UNNotificationRequest(identifier: delivery.id, content: content, trigger: trigger))
            if current != revision {
                center.removePendingNotificationRequests(withIdentifiers: [delivery.id])
                return nil
            }
        }
        return deliveries.count > 60 ? "Macの通知は直近60件を予約しています。再取得時に更新します。" : nil
    }

    func clear() throws {
        try journal.clear()
        revision = UUID()
        rules = []
        loaded = true
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

nonisolated enum ReminderError: LocalizedError {
    case denied, invalidDate
    var errorDescription: String? {
        switch self {
        case .denied: "Macの通知が許可されていません。システム設定の通知からTickTick Nativeを許可してください。"
        case .invalidDate: "タスクの開始予定と、未来の通知時刻を指定してください。"
        }
    }
}
