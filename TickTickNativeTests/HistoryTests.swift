import Foundation
import Testing
@testable import TickTickNative

extension APITests {
    @Test func completedHistoryUsesExplicitRangeAndDoesNotWriteTasks() async throws {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: "2026-10-23T12:00:00Z")!
        let api = api { request in
            #expect(request.url!.path == "/open/v1/task/completed")
            #expect(request.httpMethod == "POST")
            return (200, Data(#"[{"id":"t","projectId":"p","title":"sample","status":2,"completedTime":"2026-10-23T12:00:00Z"}]"#.utf8))
        }
        #expect(try await api.completed(from: date, through: date, token: "sample").count == 1)
    }

    @Test func historyRejectsInvalidRangeAndNonCompletedResults() async throws {
        let date = Date.now
        let api = api { _ in (200, Data(#"[{"id":"t","projectId":"p","title":"sample","status":0}]"#.utf8)) }
        await #expect(throws: TaskDateError.self) { try await api.completed(from: date, through: date.addingTimeInterval(-172800), token: "sample") }
        await #expect(throws: TickTickError.self) { try await api.completed(from: date, through: date, token: "sample") }
    }
}
