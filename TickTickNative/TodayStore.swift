import Foundation
import Observation

@MainActor
@Observable
final class TodayStore {
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

    init(isDemo: Bool = false, api: TickTickAPI = TickTickAPI()) {
        self.isDemo = isDemo
        self.api = api
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        if isDemo { await loadDemo(); return }
        do {
            connection = try ConnectionKeychain.load()
            isConnected = connection != nil
            if isConnected { await refresh() }
        } catch {
            errorMessage = "保存した接続情報を読み出せません。Keychainへのアクセスを確認してください。"
        }
    }

    func connect(clientID: String, secret: String) async {
        guard !isAuthorizing && !isLoading && !isDemo else { return }
        generation = UUID()
        let current = generation
        isAuthorizing = true
        errorMessage = nil
        defer { if generation == current { isAuthorizing = false } }
        do {
            let code = try await browser.authorize(clientID: clientID)
            guard generation == current else { return }
            let token = try await api.exchange(code: code, clientID: clientID, secret: secret)
            guard generation == current else { return }
            let connection = TickConnection(clientID: clientID, clientSecret: secret, accessToken: token)
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
        if isDemo { await loadDemo(); return }
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

    func cancelAuthorization() {
        guard isAuthorizing else { return }
        generation = UUID()
        browser.cancel()
        isAuthorizing = false
        errorMessage = TickTickError.authorizationCancelled.localizedDescription
    }

    func disconnect() {
        guard !isDemo else { return }
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
        ], projectCount: 1)
        projectCount = 1
        updatedAt = now
        await regroup(now: now)
    }
}
