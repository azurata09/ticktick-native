import Foundation

nonisolated enum TickTickError: LocalizedError {
    case updateUncertain
    case conflict
    case unsupportedTaskAttributes([String])
    case unsupportedFields
    case recurringNotSupported
    case completionUncertain
    case invalidInput
    case creationUncertain
    case unauthorized
    case http(Int)
    case invalidResponse
    case invalidCallback
    case callbackUnavailable
    case authorizationTimedOut
    case authorizationCancelled
    case pagination
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .updateUncertain: "保存結果を確認できませんでした。入力を保持しています。タスクを読み直して結果を確認してください。"
        case .conflict: "別の場所でタスクが変更されました。読み直して変更内容を確認してください。"
        case .unsupportedTaskAttributes(let names): "未対応の属性があるため送信を停止しました（属性名のみ）：" + names.sorted().joined(separator: ", ")
        case .unsupportedFields: "このタスクには未対応の情報があるため、安全に変更できません。元の内容は変更していません。"
        case .recurringNotSupported: "繰り返しタスクの完了は、繰り返し対応後に利用できます。"
        case .completionUncertain: "完了状態を確認できませんでした。更新して状態を確認してください。自動再送はしません。"
        case .invalidInput: "タイトルと保存先リストを指定してください。"
        case .creationUncertain: "追加の結果を確認できません。二重登録を防ぐため、保存先を確認するまで再送しません。"
        case .unauthorized: "認証が失効したか、権限がありません。接続し直してください。"
        case .http(let code): "TickTickへの通信に失敗しました（HTTP \(code)）。時間を置いて再試行してください。"
        case .invalidResponse: "TickTickからの応答を読み取れませんでした。"
        case .invalidCallback: "認証の応答を検証できませんでした。接続し直してください。"
        case .callbackUnavailable: "認証の受信ポートを開けません。別の認証処理を閉じて再試行してください。"
        case .authorizationTimedOut: "認証がタイムアウトしました。接続し直してください。"
        case .authorizationCancelled: "接続をキャンセルしました。"
        case .pagination: "リストを最後まで取得できませんでした。取得範囲を確認してください。"
        case .keychain(let code): "Keychainを利用できませんでした（\(code)）。"
        }
    }
}

nonisolated private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor TickTickAPI {
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    func exchange(code: String, clientID: String, secret: String, allowWrite: Bool = false) async throws -> String {
        var request = URLRequest(url: URL(string: "https://ticktick.com/oauth/token")!)
        request.httpMethod = "POST"
        let credentials = Data("\(clientID):\(secret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthFlow.form([
            "code": code,
            "grant_type": "authorization_code",
            "scope": allowWrite ? "tasks:read tasks:write" : "tasks:read",
            "redirect_uri": OAuthFlow.redirectURI
        ])
        struct Token: Decodable { let access_token: String }
        let token: Token = try await send(request)
        guard !token.access_token.isEmpty else { throw TickTickError.invalidResponse }
        return token.access_token
    }

    func snapshot(token: String) async throws -> TaskSnapshot {
        var projects: [TickProject] = []
        var seen: Set<String> = []
        while true {
            let page: [TickProject] = try await get("project", token: token, query: [
                URLQueryItem(name: "offset", value: String(projects.count)),
                URLQueryItem(name: "limit", value: "100")
            ])
            for project in page {
                guard seen.insert(project.id).inserted else { throw TickTickError.pagination }
                projects.append(project)
            }
            if page.count < 100 { break }
        }
        var result = TaskSnapshot()
        for project in projects where project.closed != true {
            try Task.checkCancellation()
            do {
                let data: ProjectData = try await get("project/\(project.id)/data", token: token)
                result.tasks += data.tasks.map { ListedTask(task: $0, projectName: project.name) }
                result.projectCount += 1
                result.projects.append(project)
            } catch TickTickError.unauthorized {
                throw TickTickError.unauthorized
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                result.warnings.append("「\(project.name)」を取得できませんでした。更新して再試行してください。")
            }
        }
        return result
    }

    func create(title: String, projectID: String, date: Date, token: String) async throws -> TickTask {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !projectID.isEmpty else { throw TickTickError.invalidInput }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let rawDate = formatter.string(from: Calendar.current.startOfDay(for: date))
        let body: [String: Any] = ["title": title, "projectId": projectID, "isAllDay": true,
                                    "startDate": rawDate, "dueDate": rawDate,
                                    "timeZone": TimeZone.current.identifier]
        var request = URLRequest(url: URL(string: "https://api.ticktick.com/open/v1/task")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let task: TickTask = try await send(request)
        guard !task.id.isEmpty, task.projectId == projectID else { throw TickTickError.creationUncertain }
        return task
    }

    func task(projectID: String, taskID: String, token: String) async throws -> TickTask {
        try await get("project/\(projectID)/task/\(taskID)", token: token)
    }

    func record(projectID: String, taskID: String, token: String) async throws -> TaskRecord {
        let record: TaskRecord = try await get("project/\(projectID)/task/\(taskID)", token: token)
        guard record.fields["id"]?.string == taskID, record.fields["projectId"]?.string == projectID else { throw TickTickError.invalidResponse }
        return record
    }

    func update(record: TaskRecord, changes: [String: JSONValue], token: String) async throws -> TaskRecord {
        let original = try record.task()
        let current = try await self.record(projectID: original.projectId, taskID: original.id, token: token)
        guard current == record else { throw TickTickError.conflict }
        let body = try current.updating(changes)
        var request = URLRequest(url: URL(string: "https://api.ticktick.com/open/v1/task/\(original.id)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        var failure: Error?
        do { _ = try await perform(request) } catch { failure = error }
        let confirmed = try await self.record(projectID: original.projectId, taskID: original.id, token: token)
        guard confirmed.confirms(changes) else { throw failure ?? TickTickError.updateUncertain }
        return confirmed
    }

    func complete(projectID: String, taskID: String, token: String, expected: TickTask? = nil) async throws -> TickTask {
        let current = try await task(projectID: projectID, taskID: taskID, token: token)
        if current.status == 2 { return current }
        if current.repeatFlag?.isEmpty == false {
            guard SimpleRecurrence.matching(current.repeatFlag) != nil, let expected else { throw TickTickError.recurringNotSupported }
            guard current.dueDate == expected.dueDate, current.startDate == expected.startDate else { throw TickTickError.conflict }
        }
        var request = URLRequest(url: URL(string: "https://api.ticktick.com/open/v1/project/\(projectID)/task/\(taskID)/complete")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var failure: Error?
        do { _ = try await perform(request) }
        catch { failure = error }
        let confirmed = try await task(projectID: projectID, taskID: taskID, token: token)
        if confirmed.status == 2 { return confirmed }
        if current.repeatFlag?.isEmpty == false,
           let beforeRaw = current.dueDate, let afterRaw = confirmed.dueDate {
            let schedule = TaskSchedule(calendar: .current)
            if let before = schedule.date(beforeRaw, allDay: current.isAllDay == true),
               let after = schedule.date(afterRaw, allDay: confirmed.isAllDay == true), after > before { return confirmed }
        }
        throw failure ?? TickTickError.completionUncertain
    }

    private func get<T: Decodable>(_ path: String, token: String, query: [URLQueryItem] = []) async throws -> T {
        var url = URLComponents(string: "https://api.ticktick.com/open/v1/\(path)")!
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await perform(request)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw TickTickError.invalidResponse }
    }

    private func perform(_ input: URLRequest) async throws -> Data {
        var request = input
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TickTickError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw TickTickError.unauthorized }
        guard (200..<300).contains(response.statusCode) else { throw TickTickError.http(response.statusCode) }
        return data
    }
}
