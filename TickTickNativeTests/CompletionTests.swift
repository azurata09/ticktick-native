import Foundation
import Testing
@testable import TickTickNative

extension APITests {
    @Test func emptyCompletionResponseIsConfirmedByReadback() async throws {
        var completed = false
        var posts = 0
        let api = api { request in
            if request.httpMethod == "POST" { posts += 1; completed = true; return (200,Data()) }
            return (200,Data("{\"id\":\"t\",\"projectId\":\"p\",\"title\":\"sample\",\"status\":\(completed ? 2 : 0)}".utf8))
        }
        #expect(try await api.complete(projectID: "p", taskID: "t", token: "sample").status == 2)
        #expect(try await api.complete(projectID: "p", taskID: "t", token: "sample").status == 2)
        #expect(posts == 1)
    }

    @Test func lostCompletionResponseDoesNotCauseASecondWrite() async throws {
        var completed = false
        var posts = 0
        let api = api { request in
            if request.httpMethod == "POST" { posts += 1; completed = true; throw URLError(.timedOut) }
            return (200,Data("{\"id\":\"t\",\"projectId\":\"p\",\"title\":\"sample\",\"status\":\(completed ? 2 : 0)}".utf8))
        }
        #expect(try await api.complete(projectID: "p", taskID: "t", token: "sample").status == 2)
        #expect(posts == 1)
    }

    @Test func recurringTaskIsNotAccidentallyCompleted() async {
        let api = api { request in
            #expect(request.httpMethod == "GET")
            return (200,Data(#"{"id":"t","projectId":"p","title":"sample","repeatFlag":"RRULE:FREQ=DAILY"}"#.utf8))
        }
        await #expect(throws: TickTickError.self) { try await api.complete(projectID: "p", taskID: "t", token: "sample") }
    }

    @MainActor @Test func demoCompletionRemovesTaskFromToday() async {
        let api = api { _ in Issue.record("demo must not contact API"); return (500,Data()) }
        let store = TodayStore(isDemo: true, api: api)
        await store.restore()
        #expect(await store.completeTask(store.today[0]))
        #expect(store.today.isEmpty)
        await store.refresh()
        #expect(store.today.isEmpty)
    }
}
