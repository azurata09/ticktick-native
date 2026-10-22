import Foundation
import Observation

@MainActor
@Observable
final class TodayStore {
    var operationMessage: String?
    var reminderMessage: String?
    private var reminders: MacReminders?
    var isSavingTask = false
    var pendingCompletions: [CompletionReceipt] = []
    var completionRecordError = false
    var pendingCreation: PendingCreation?
    var creationRecordError = false
    var canWrite: Bool { self.isDemo || self.connection?.canWrite == true }
    var writableProjects: [TickProject] { snapshot.projects.filter { $0.isWritable && $0.kind != "NOTE" } }
    var today: [ListedTask] = []
    var overdue: [ListedTask] = []
    var warnings: [String] = []
    var errorMessage: String?
    var isLoading = false
    var isAuthorizing = false
    var isConnected = false
    var needsAuthorization = false
    var updatedAt: Date?
    var projectCount = 0
    let isDemo: Bool

    private let completionJournal: CompletionJournal
    private let creationJournal: CreationJournal
    private let api: TickTickAPI
    private let browser = OAuthBrowser()
    var savedClientID: String { connection?.clientID ?? "" }
    var savedClientSecret: String { connection?.clientSecret ?? "" }

    private var refreshTask: Task<TaskSnapshot, Error>?
    private var connection: TickConnection?
    private var generation = UUID()
    private var groupingID = UUID()
    private var restored = false
    private var snapshot = TaskSnapshot()

    init(isDemo: Bool = false, api: TickTickAPI = TickTickAPI(), initialConnection: TickConnection? = nil, creationJournal: CreationJournal = CreationJournal(), completionJournal: CompletionJournal = CompletionJournal(filename: "pending-completions.json")) {
        self.isDemo = isDemo
        self.api = api
        self.connection = initialConnection
        self.creationJournal = creationJournal
        self.completionJournal = completionJournal
        self.isConnected = initialConnection != nil
        if !isDemo && initialConnection == nil && ProcessInfo.processInfo.environment["TICKTICK_TESTING"] != "1" { reminders = MacReminders() }
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        if isDemo { await loadDemo(); return }
        do { pendingCompletions = try completionJournal.load() ?? [] }
        catch { completionRecordError = true; errorMessage = "完了記録を読み出せないため、完了操作を停止しています。" }
        do { pendingCreation = try creationJournal.load() }
        catch { creationRecordError = true; errorMessage = "追加記録を読み出せません。二重登録を防ぐため追加を停止しています。" }
        do {
            if connection == nil { connection = try ConnectionKeychain.load() }
            isConnected = connection != nil
            if isConnected { await refresh() }
        } catch {
            errorMessage = "保存した接続情報を読み出せません。Keychainへのアクセスを確認してください。"
        }
    }

    func connect(clientID: String, secret: String, allowWrite: Bool = false) async {
        guard !isAuthorizing && !isLoading && !isSavingTask && pendingCreation == nil && pendingCompletions.isEmpty && !completionRecordError && !isDemo else { return }
        generation = UUID()
        let current = generation
        isAuthorizing = true
        errorMessage = nil
        defer { if generation == current { isAuthorizing = false } }
        do {
            let code = try await browser.authorize(clientID: clientID, allowWrite: allowWrite)
            guard generation == current else { return }
            let token = try await api.exchange(code: code, clientID: clientID, secret: secret, allowWrite: allowWrite)
            guard generation == current else { return }
            let connection = TickConnection(clientID: clientID, clientSecret: secret, accessToken: token, canWrite: allowWrite)
            try ConnectionKeychain.save(connection)
            clearSnapshot()
            self.connection = connection
            isConnected = true
            needsAuthorization = false
            await refresh()
        } catch {
            guard generation == current else { return }
            errorMessage = message(for: error)
        }
    }

    func refresh() async {
        if isDemo { updatedAt = .now; await regroup(); return }
        guard !isLoading, let connection else { return }
        let current = generation
        isLoading = true
        errorMessage = nil
        let task = Task { try await api.snapshot(token: connection.accessToken) }
        refreshTask = task
        defer {
            if generation == current {
                isLoading = false
                refreshTask = nil
            }
        }
        do {
            let snapshot = try await task.value
            guard generation == current else { return }
            self.snapshot = snapshot
            projectCount = snapshot.projectCount
            updatedAt = .now
            needsAuthorization = false
            try await reconcileCompletions()
            await syncReminders()
            await regroup()
        } catch {
            guard generation == current else { return }
            if case TickTickError.unauthorized = error { needsAuthorization = true }
            errorMessage = message(for: error)
        }
    }

    func completeTask(_ item: ListedTask) async -> Bool {
        guard canWrite, !isSavingTask, !isAuthorizing, !isLoading, !needsAuthorization else { return false }
        if let project = snapshot.projects.first(where: { $0.id == item.task.projectId }), !project.isWritable { return false }
        guard !completionRecordError, !pendingCompletions.contains(where: { $0.taskID == item.task.id && $0.projectID == item.task.projectId }) else {
            errorMessage = "前回の完了結果が未確認です。更新して確認してください。再送していません。"
            return false
        }
        guard SimpleRecurrence.matching(item.task.repeatFlag) != nil else {
            errorMessage = TickTickError.recurringNotSupported.localizedDescription
            return false
        }
        isSavingTask = true
        errorMessage = nil
        operationMessage = nil
        defer { isSavingTask = false }
        do {
            var confirmed = item.task
            if isDemo { confirmed.status = 2 }
            else if let connection {
                if item.task.repeatFlag?.isEmpty == false {
                    let receipt = CompletionReceipt(taskID: item.task.id, projectID: item.task.projectId, previousDue: item.task.dueDate)
                    try completionJournal.save(pendingCompletions + [receipt])
                    pendingCompletions.append(receipt)
                }
                confirmed = try await api.complete(projectID: item.task.projectId, taskID: item.task.id, token: connection.accessToken, expected: item.task)
                try clearCompletion(taskID: item.task.id, projectID: item.task.projectId)
            } else { return false }
            if item.task.repeatFlag?.isEmpty == false,
               let raw = confirmed.dueDate,
               let date = TaskSchedule(calendar: .current).date(raw, allDay: confirmed.isAllDay == true) {
                operationMessage = "完了を確認しました。次回予定：" + date.formatted(date: .abbreviated, time: confirmed.isAllDay == true ? .omitted : .shortened)
            }
            if let index = snapshot.tasks.firstIndex(where: { $0.id == item.id }) {
                snapshot.tasks[index] = ListedTask(task: confirmed, projectName: item.projectName)
            }
            await syncReminders()
            await regroup()
            if !isDemo { await refresh() }
            return true
        } catch {
            if case TickTickError.unauthorized = error { needsAuthorization = true }
            errorMessage = message(for: error)
            return false
        }
    }

    func resolvePendingCompletions() {
        guard !isSavingTask else { return }
        do {
            try completionJournal.clear()
            pendingCompletions = []
            completionRecordError = false
        } catch { errorMessage = "完了記録を解除できませんでした。" }
    }

    private func clearCompletion(taskID: String, projectID: String) throws {
        let remaining = pendingCompletions.filter { $0.taskID != taskID || $0.projectID != projectID }
        if remaining.isEmpty { try completionJournal.clear() } else { try completionJournal.save(remaining) }
        pendingCompletions = remaining
    }

    private func reconcileCompletions() async throws {
        guard let connection else { return }
        for receipt in pendingCompletions {
            let task = try await api.task(projectID: receipt.projectID, taskID: receipt.taskID, token: connection.accessToken)
            let schedule = TaskSchedule(calendar: .current)
            let before = receipt.previousDue.flatMap { schedule.date($0, allDay: task.isAllDay == true) }
            let after = task.dueDate.flatMap { schedule.date($0, allDay: task.isAllDay == true) }
            if task.status == 2 || (before != nil && after != nil && after! > before!) {
                try clearCompletion(taskID: receipt.taskID, projectID: receipt.projectID)
            }
        }
    }

    func setReminder(for item: ListedTask, date: Date?) async -> Bool {
        guard let reminders, !isSavingTask, !isLoading, isConnected else { return false }
        isSavingTask = true
        defer { isSavingTask = false }
        do {
            try await reminders.set(task: item.task, date: date)
            await syncReminders()
            return reminderMessage == nil
        } catch { reminderMessage = error.localizedDescription; return false }
    }

    private func syncReminders() async {
        guard let reminders else { return }
        do { reminderMessage = try await reminders.synchronize(snapshot: snapshot) }
        catch { reminderMessage = error.localizedDescription }
    }

    func record(for item: ListedTask) async throws -> TaskRecord {
        if isDemo {
            var record = try JSONDecoder().decode(TaskRecord.self, from: JSONEncoder().encode(item.task))
            record.fields["content"] = .string(String(repeating: "作業の背景と確認する手順をここに表示します。\n", count: 12))
            record.fields["priority"] = .integer(3)
            record.fields["items"] = .array([.object(["title": .string("手順を確認する"), "status": .integer(1)]), .object(["title": .string("実行する"), "status": .integer(0)])])
            return record
        }
        guard let connection else { throw TickTickError.unauthorized }
        return try await api.record(projectID: item.task.projectId, taskID: item.task.id, token: connection.accessToken)
    }

    func saveRecurrence(record: TaskRecord, date: Date, allDay: Bool, recurrence: SimpleRecurrence) async -> Bool {
        guard canWrite, !isSavingTask, !isLoading, !needsAuthorization, let connection else { return false }
        isSavingTask = true
        defer { isSavingTask = false }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let value = formatter.string(from: allDay ? Calendar.current.startOfDay(for: date) : date)
        do {
            let confirmed = try await api.update(record: record, changes: ["startDate": .string(value), "dueDate": .string(value),
                "isAllDay": .bool(allDay), "timeZone": .string(TimeZone.current.identifier), "repeatFlag": .string(recurrence.rule)], token: connection.accessToken)
            guard confirmed.fields["repeatFlag"]?.string == recurrence.rule else { throw TickTickError.invalidResponse }
            await refresh()
            return true
        } catch { errorMessage = message(for: error); return false }
    }

    func createTask(title: String, projectID: String) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !projectID.isEmpty else { errorMessage = TickTickError.invalidInput.localizedDescription; return false }
        guard canWrite, !isSavingTask, !isAuthorizing, !isLoading, !needsAuthorization,
              pendingCreation == nil, !creationRecordError else {
            errorMessage = "書き込み権限、通信状態、未確認の追加記録を確認してください。"
            return false
        }
        isSavingTask = true
        errorMessage = nil
        defer { isSavingTask = false }
        if isDemo {
            snapshot.tasks.append(ListedTask(task: TickTask(id: UUID().uuidString, projectId: projectID, title: title,
                                                          dueDate: ISO8601DateFormatter().string(from: .now)), projectName: "サンプル"))
            await regroup()
            return true
        }
        guard let connection else { return false }
        var pending = PendingCreation(title: title, projectID: projectID, date: .now)
        do {
            try creationJournal.save(pending)
            pendingCreation = pending
        } catch { errorMessage = "追加記録を保存できないため、タスクを送信していません。"; return false }
        do {
            let created = try await api.create(title: title, projectID: projectID, date: pending.date, token: connection.accessToken)
            pending.serverID = created.id
            pendingCreation = pending
            try creationJournal.save(pending)
            let confirmed = try await api.task(projectID: projectID, taskID: created.id, token: connection.accessToken)
            guard confirmed.id == created.id, confirmed.projectId == projectID else { throw TickTickError.creationUncertain }
            try creationJournal.clear()
            pendingCreation = nil
            let name = snapshot.projects.first { $0.id == projectID }?.name ?? "保存先リスト"
            snapshot.tasks.append(ListedTask(task: confirmed, projectName: name))
            await regroup()
            await refresh()
            return true
        } catch {
            var rejected = false
            if pending.serverID == nil {
                switch error {
                case TickTickError.unauthorized: rejected = true; needsAuthorization = true
                case TickTickError.http(let status): rejected = [400, 404, 422].contains(status)
                default: break
                }
            }
            if rejected {
                do { try creationJournal.clear(); pendingCreation = nil }
                catch { creationRecordError = true }
                errorMessage = message(for: error)
            } else {
                errorMessage = TickTickError.creationUncertain.localizedDescription
            }
            return false
        }
    }

    func resolvePendingCreation() {
        guard !isSavingTask else { return }
        do {
            try creationJournal.clear()
            pendingCreation = nil
            creationRecordError = false
            errorMessage = nil
        } catch { errorMessage = "追加記録を解除できませんでした。" }
    }

    func cancelAuthorization() {
        guard isAuthorizing else { return }
        generation = UUID()
        browser.cancel()
        isAuthorizing = false
        errorMessage = TickTickError.authorizationCancelled.localizedDescription
    }

    func disconnect() {
        guard !isDemo else { return }
        guard !isSavingTask, pendingCreation == nil, !creationRecordError, pendingCompletions.isEmpty, !completionRecordError else {
            errorMessage = "追加処理または未確認の追加記録が残っています。保存結果を確認してから接続を解除してください。"
            return
        }
        do { try reminders?.clear(); reminderMessage = nil }
        catch { errorMessage = "通知設定を消せませんでした。接続解除を停止しました。"; return }
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        browser.cancel()
        isAuthorizing = false
        isLoading = false
        connection = nil
        isConnected = false
        needsAuthorization = false
        clearSnapshot()
        errorMessage = nil
        do { try ConnectionKeychain.delete() }
        catch { errorMessage = "接続を停止しましたが、Keychainの情報を消せませんでした。接続解除を再試行してください。" }
    }

    private func clearSnapshot() {
        snapshot = TaskSnapshot()
        today = []
        overdue = []
        warnings = []
        updatedAt = nil
        projectCount = 0
    }

    func regroup(now: Date = .now, calendar: Calendar = .current) async {
        let id = UUID()
        groupingID = id
        let current = generation
        let snapshot = snapshot
        let groups = await Task.detached {
            var today: [ListedTask] = []
            var overdue: [ListedTask] = []
            var warnings = snapshot.warnings
            let schedule = TaskSchedule(calendar: calendar)
            var invalidCount = 0
            var seen: Set<String> = []
            for item in snapshot.tasks where seen.insert(item.id).inserted {
                switch schedule.bucket(item.task, now: now) {
                case .today: today.append(item)
                case .overdue: overdue.append(item)
                case .invalidDate: invalidCount += 1
                case .other, .unscheduled: break
                }
            }
            today.sort { $0.task.title.localizedStandardCompare($1.task.title) == .orderedAscending }
            overdue.sort { $0.task.title.localizedStandardCompare($1.task.title) == .orderedAscending }
            if invalidCount > 0 {
                warnings.append("日時を解釈できないタスクが\(invalidCount)件あります。一覧には含めていません。")
            }
            return (today, overdue, warnings)
        }.value
        guard generation == current, groupingID == id else { return }
        today = groups.0
        overdue = groups.1
        warnings = groups.2
    }

    private func message(for error: Error) -> String {
        if let error = error as? TickTickError { return error.localizedDescription }
        return "通信できませんでした。ネットワーク接続を確認して再試行してください。"
    }

    private func loadDemo() async {
        let formatter = ISO8601DateFormatter()
        let now = Date.now
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        snapshot = TaskSnapshot(tasks: [
            ListedTask(task: TickTask(id: "sample1", projectId: "sample", title: "今日取り組む作業を確認する", dueDate: formatter.string(from: now)), projectName: "サンプル"),
            ListedTask(task: TickTask(id: "sample2", projectId: "sample", title: "昨日の作業を見直す", dueDate: formatter.string(from: yesterday)), projectName: "サンプル")
        ], projectCount: 1, projects: [TickProject(id: "sample", name: "サンプル")])
        projectCount = 1
        updatedAt = now
        await regroup(now: now)
    }
}
