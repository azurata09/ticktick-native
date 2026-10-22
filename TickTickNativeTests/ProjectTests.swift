import Foundation
import Testing
@testable import TickTickNative

extension APITests {
    @MainActor @Test func projectViewKeepsUndatedTasksAndEmptyProjects() async {
        let api = api { request in
            switch request.url!.path {
            case "/open/v1/project": return (200, Data(#"[{"id":"p","name":"sample"},{"id":"empty","name":"empty sample"}]"#.utf8))
            case "/open/v1/project/p/data": return (200, Data(#"{"tasks":[{"id":"t","projectId":"p","title":"undated"},{"id":"done","projectId":"p","title":"done","status":2}]}"#.utf8))
            default: return (200, Data(#"{"tasks":[]}"#.utf8))
            }
        }
        let connection = TickConnection(clientID: "sample", clientSecret: "sample", accessToken: "sample")
        let store = TodayStore(api: api, initialConnection: connection)
        await store.refresh()
        #expect(store.projects.count == 2)
        #expect(store.projectTasks["p"]?.map(\.task.id) == ["t"])
        #expect(store.today.isEmpty)
        #expect(store.projects.contains { $0.id == "empty" })
    }
}
