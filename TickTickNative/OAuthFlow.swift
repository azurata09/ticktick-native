import AppKit
import Network

@MainActor
final class OAuthBrowser {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var pending: CheckedContinuation<String, Error>?
    private var requestID = UUID()
    private var timeoutTask: Task<Void, Never>?
    private let openURL: (URL) -> Bool

    init(openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openURL = openURL
    }

    func authorize(clientID: String) async throws -> String {
        cancel()
        let id = UUID()
        requestID = id
        let state = UUID().uuidString + UUID().uuidString
        let url = OAuthFlow.authorizationURL(clientID: clientID, state: state)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: OAuthFlow.port)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            listener.stateUpdateHandler = { [weak self] status in
                Task { @MainActor in
                    guard let self, self.requestID == id else { return }
                    switch status {
                    case .ready:
                        if !self.openURL(url) { self.finish(.failure(TickTickError.invalidCallback)) }
                    case .failed:
                        self.finish(.failure(TickTickError.callbackUnavailable))
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.requestID == id else { connection.cancel(); return }
                    self.connections.append(connection)
                    connection.start(queue: .main)
                    self.receive(connection, bytes: Data(), state: state, id: id)
                }
            }
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(180)) }
                catch { return }
                guard self?.requestID == id else { return }
                self?.finish(.failure(TickTickError.authorizationTimedOut))
            }
            listener.start(queue: .main)
        }
    }

    private func receive(_ connection: NWConnection, bytes: Data, state: String, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - bytes.count) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.requestID == id else { connection.cancel(); return }
                let bytes = bytes + (data ?? Data())
                guard bytes.count < 8192 else { self.reply(connection, status: "400 Bad Request"); return }
                if let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") {
                    do {
                        let url = try OAuthFlow.callbackURL(from: text)
                        let code = try OAuthFlow.code(from: url, state: state)
                        self.reply(connection, status: "200 OK") { [weak self] in
                            guard self?.requestID == id else { return }
                            self?.finish(.success(code))
                        }
                    } catch TickTickError.authorizationCancelled {
                        self.reply(connection, status: "200 OK") { [weak self] in
                            guard self?.requestID == id else { return }
                            self?.finish(.failure(TickTickError.authorizationCancelled))
                        }
                    } catch { self.reply(connection, status: "400 Bad Request") }
                } else if complete || error != nil {
                    self.reply(connection, status: "400 Bad Request")
                } else {
                    self.receive(connection, bytes: bytes, state: state, id: id)
                }
            }
        }
    }

    private func reply(_ connection: NWConnection, status: String, completion: (() -> Void)? = nil) {
        let body = "You can close this tab and return to TickTick Native."
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                connection.cancel()
                self?.connections.removeAll { $0 === connection }
                completion?()
            }
        })
    }

    func cancel() { finish(.failure(TickTickError.authorizationCancelled)) }

    private func finish(_ result: Result<String, Error>) {
        requestID = UUID()
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections = []
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}

nonisolated enum OAuthFlow {
    static let port = NWEndpoint.Port(rawValue: 49217)!
    static let redirectURI = "http://127.0.0.1:49217/callback"

    static func authorizationURL(clientID: String, state: String) -> URL {
        var url = URLComponents(string: "https://ticktick.com/oauth/authorize")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: "tasks:read"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code")
        ]
        return url.url!
    }

    static func callbackURL(from request: String) throws -> URL {
        let lines = request.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1",
              first[1].hasPrefix("/"), hosts.count == 1,
              hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:49217",
              let url = URL(string: "http://127.0.0.1:49217\(first[1])") else {
            throw TickTickError.invalidCallback
        }
        return url
    }

    static func code(from url: URL, state: String) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", parts.port == 49217,
              parts.path == "/callback", parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw TickTickError.invalidCallback
        }
        let items = parts.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        let codes = items.filter { $0.name == "code" }
        guard states.count == 1, states.first?.value == state else { throw TickTickError.invalidCallback }
        if items.contains(where: { $0.name == "error" && $0.value == "access_denied" }) {
            throw TickTickError.authorizationCancelled
        }
        guard !items.contains(where: { $0.name == "error" }),
              codes.count == 1, let code = codes.first?.value, !code.isEmpty else {
            throw TickTickError.invalidCallback
        }
        return code
    }

    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted(by: { $0.key < $1.key }).map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "="
                + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}
