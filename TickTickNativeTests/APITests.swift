import Foundation
import Testing
@testable import TickTickNative

nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite("API", .serialized)
struct APITests {
    func api(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> TickTickAPI {
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return TickTickAPI(session: URLSession(configuration: configuration))
    }

    @Test func partialFailuresAreReportedWithoutLosingOtherLists() async throws {
        let api = api { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sample-token")
            switch request.url!.path {
            case "/open/v1/project":
                return (200, Data(#"[{"id":"p1","name":"sample one"},{"id":"p2","name":"sample two"},{"id":"p3","name":"closed","closed":true}]"#.utf8))
            case "/open/v1/project/p1/data":
                return (200, Data(#"{"tasks":[{"id":"t1","projectId":"p1","title":"sample task","dueDate":"2026-10-23T00:00:00+0000"}]}"#.utf8))
            case "/open/v1/project/p2/data": return (503, Data())
            default: Issue.record("unexpected request"); return (404, Data())
            }
        }
        let result = try await api.snapshot(token: "sample-token")
        #expect(result.tasks.count == 1)
        #expect(result.projectCount == 1)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].contains("sample two"))
    }

    @Test func unauthorizedDoesNotLookLikeAnEmptyList() async {
        let api = api { _ in (401, Data()) }
        await #expect(throws: TickTickError.self) {
            try await api.snapshot(token: "sample-token")
        }
    }

    @Test func malformedDataIsNotAnEmptySuccess() async {
        let api = api { _ in (200, Data("not-json".utf8)) }
        await #expect(throws: TickTickError.self) {
            try await api.snapshot(token: "sample-token")
        }
    }

    @Test func repeatedPaginationCannotSilentlyOmitProjects() async {
        let projects = (0..<100).map { ["id": "p\($0)", "name": "sample"] }
        let data = try! JSONSerialization.data(withJSONObject: projects)
        let api = api { _ in (200, data) }
        await #expect(throws: TickTickError.self) {
            try await api.snapshot(token: "sample-token")
        }
    }

    @Test func tokenExchangeUsesBasicAuthAndFormBody() async throws {
        let api = api { request in
            #expect(request.url?.absoluteString == "https://ticktick.com/oauth/token")
            #expect(request.httpMethod == "POST")
            let expected = Data("sample-client:sample-secret".utf8).base64EncodedString()
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic \(expected)")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            return (200, Data(#"{"access_token":"sample-token"}"#.utf8))
        }
        #expect(try await api.exchange(code: "a+b", clientID: "sample-client", secret: "sample-secret") == "sample-token")
    }

    @MainActor @Test func demoDoesNotContactAPI() async {
        let api = api { _ in Issue.record("demo must not use the network"); return (500, Data()) }
        let store = TodayStore(isDemo: true, api: api)
        await store.restore()
        await store.refresh()
        #expect(store.today.count == 1)
        #expect(store.overdue.count == 1)
        #expect(!store.isConnected)
    }
}
