import Foundation
import Observation

@MainActor
@Observable
final class TodayStore {
    var isSavingTask = false
    var pendingCreation: PendingCreation?
    var creationRecordError = false
    var canWrite: Bool { self.isDemo || self.connection?.canWrite == true }
    var writableProjects: [TickProject] { snapshot.projects.filter { $0.permission != "read" && $0.kind != "NOTE" } }
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

    init(isDemo: Bool = false, api: TickTickAPI = TickTickAPI(), initialConnection: TickConnection? = nil, creationJournal: CreationJournal = CreationJournal()) {
        self.isDemo = isDemo
        self.api = api
        self.connection = initialConnection
        self.creationJournal = creationJournal
        self.isConnected = initialConnection != nil
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        if isDemo { await loadDemo(); return }
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
        guard !isAuthorizing && !isLoading && !isSavingTask && pendingCreation == nil && !isDemo else { return }
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
            await regroup()
        } catch {
            guard generation == current else { return }
            if case TickTickError.unauthorized = error { needsAuthorization = true }
            errorMessage = message(for: error)
        }
    }

    func completeTask(_ item: ListedTask) async -> Bool {
        guard canWrite, !isSavingTask, !isAuthorizing, !isLoading, !needsAuthorization else { return false }
        guard item.task.repeatFlag?.isEmpty != false else {
            errorMessage = TickTickError.recurringNotSupported.localizedDescription
            return false
        }
        isSavingTask = true
        errorMessage = nil
        defer { isSavingTask = false }
        do {
            var confirmed = item.task
            if isDemo { confirmed.status = 2 }
            else if let connection {
                confirmed = try await api.complete(projectID: item.task.projectId, taskID: item.task.id, token: connection.accessToken)
            } else { return false }
            if let index = snapshot.tasks.firstIndex(where: { $0.id == item.id }) {
                snapshot.tasks[index] = ListedTask(task: confirmed, projectName: item.projectName)
            }
            await regroup()
            if !isDemo { await refresh() }
            return true
        } catch {
            if case TickTickError.unauthorized = error { needsAuthorization = true }
            errorMessage = message(for: error)
            return false
        }
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
        guard !isSavingTask, pendingCreation == nil, !creationRecordError else {
            errorMessage = "追加処理または未確認の追加記録が残っています。保存結果を確認してから接続を解除してください。"
            return
        }
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
