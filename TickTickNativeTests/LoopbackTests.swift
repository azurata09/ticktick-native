import Foundation
import Testing
@testable import TickTickNative

@Suite("HTTP認証コールバック", .serialized)
struct LoopbackTests {
    @MainActor @Test func cancelResumesThePendingAuthorization() async {
        weak var activeBrowser: OAuthBrowser?
        let browser = OAuthBrowser { _ in
            activeBrowser?.cancel()
            return true
        }
        activeBrowser = browser
        do {
            _ = try await browser.authorize(clientID: "sample-client")
            Issue.record("cancel must stop authorization")
        } catch TickTickError.authorizationCancelled {
        } catch {
            Issue.record("unexpected cancellation result")
        }
    }

    @Test func rejectsForeignHostAndUnexpectedRequestMethod() throws {
        let request = "GET /callback?code=sample&state=expected HTTP/1.1\r\nHost: 127.0.0.1:49217\r\n\r\n"
        let url = try OAuthFlow.callbackURL(from: request)
        #expect(try OAuthFlow.code(from: url, state: "expected") == "sample")
        let invalid = [
            request.replacingOccurrences(of: "Host: 127.0.0.1:49217", with: "Host: example.com"),
            request.replacingOccurrences(of: "GET ", with: "POST "),
            request.replacingOccurrences(of: "Host: 127.0.0.1:49217", with: ""),
            request.replacingOccurrences(of: "Host: 127.0.0.1:49217", with: "Host: 127.0.0.1:49217\r\nHost: example.com")
        ]
        for text in invalid {
            #expect(throws: TickTickError.self) { try OAuthFlow.callbackURL(from: text) }
        }
    }

    @MainActor @Test func acceptsValidCallbackAfterRejectingWrongState() async throws {
        var callbackTask: Task<Void, Error>?
        let browser = OAuthBrowser { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
            callbackTask = Task {
                var callback = URLComponents(string: OAuthFlow.redirectURI)!
                callback.queryItems = [URLQueryItem(name: "code", value: "sample-code"), URLQueryItem(name: "state", value: "wrong")]
                let session = URLSession(configuration: .ephemeral)
                let (_, rejected) = try await session.data(from: callback.url!)
                #expect((rejected as? HTTPURLResponse)?.statusCode == 400)
                callback.queryItems = [URLQueryItem(name: "code", value: "sample-code"), URLQueryItem(name: "state", value: state)]
                let (body, accepted) = try await session.data(from: callback.url!)
                #expect((accepted as? HTTPURLResponse)?.statusCode == 200)
                #expect(!String(decoding: body, as: UTF8.self).contains("sample-code"))
            }
            return true
        }
        #expect(try await browser.authorize(clientID: "sample-client") == "sample-code")
        try await callbackTask?.value
        browser.cancel()
    }
}
