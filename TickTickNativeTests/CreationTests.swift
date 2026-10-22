import Foundation
import Testing
@testable import TickTickNative

extension APITests {
    private func journal() -> CreationJournal {
        CreationJournal(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pending.json"))
    }
    private var writeConnection: TickConnection {
        TickConnection(clientID: "sample", clientSecret: "sample", accessToken: "sample", canWrite: true)
    }

    @MainActor @Test func creationIsConfirmedByReadingItBack() async throws {
        let journal = journal()
        var posts = 0
        let formatter = ISO8601DateFormatter()
        let task = try JSONSerialization.data(withJSONObject: ["id":"created", "projectId":"p", "title":"sample", "dueDate":formatter.string(from: .now)])
        let api = api { request in
            switch request.url!.path {
            case "/open/v1/task": posts += 1; return (200, task)
            case "/open/v1/project/p/task/created": return (200, task)
            case "/open/v1/project": return (200, Data(#"[{"id":"p","name":"sample"}]"#.utf8))
            case "/open/v1/project/p/data": return (200, Data("{\"tasks\":[\(String(decoding:task,as:UTF8.self))]}".utf8))
            default: Issue.record("unexpected request"); return (404,Data())
            }
        }
        let store = TodayStore(api: api, initialConnection: writeConnection, creationJournal: journal)
        #expect(await store.createTask(title: " sample ", projectID: "p"))
        #expect(posts == 1)
        #expect(store.today.count == 1)
        #expect(try journal.load() == nil)
    }

    @MainActor @Test func uncertainCreationCannotBeResentEvenAfterRelaunch() async throws {
        let journal = journal()
        var posts = 0
        let api = api { request in
            if request.httpMethod == "POST" { posts += 1; throw URLError(.timedOut) }
            return (200, Data("[]".utf8))
        }
        let store = TodayStore(api: api, initialConnection: writeConnection, creationJournal: journal)
        #expect(!(await store.createTask(title: "sample", projectID: "p")))
        #expect(try journal.load()?.title == "sample")
        #expect(!(await store.createTask(title: "sample", projectID: "p")))
        let relaunched = TodayStore(api: api, initialConnection: writeConnection, creationJournal: journal)
        await relaunched.restore()
        #expect(!(await relaunched.createTask(title: "sample", projectID: "p")))
        #expect(posts == 1)
        relaunched.resolvePendingCreation()
        #expect(try journal.load() == nil)
    }

    @MainActor @Test func definiteRejectionDoesNotLeaveAnUncertainReceipt() async throws {
        let journal = journal()
        let api = api { _ in (400,Data()) }
        let store = TodayStore(api: api, initialConnection: writeConnection, creationJournal: journal)
        #expect(!(await store.createTask(title: "sample", projectID: "p")))
        #expect(store.pendingCreation == nil)
        #expect(try journal.load() == nil)
    }

    @MainActor @Test func invalidAndReadOnlyCreationsNeverReachTheNetwork() async {
        let api = api { _ in Issue.record("must not send invalid creation"); return (500,Data()) }
        let read = TickConnection(clientID: "sample", clientSecret: "sample", accessToken: "sample")
        let store = TodayStore(api: api, initialConnection: read, creationJournal: journal())
        #expect(!(await store.createTask(title: "sample", projectID: "p")))
        #expect(!(await store.createTask(title: "  ", projectID: "p")))
    }
}
