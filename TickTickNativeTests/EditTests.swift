import Foundation
import Testing
@testable import TickTickNative

extension APITests {
    @Test func unchangedReadbackIsNotReportedAsSaved() async throws {
        let original = TaskRecord(fields: ["id": .string("t"), "projectId": .string("p"), "title": .string("sample")])
        var posts = 0
        let api = api { request in
            if request.httpMethod == "POST" { posts += 1; return (200, Data()) }
            return (200, try JSONEncoder().encode(original))
        }
        await #expect(throws: TickTickError.self) { try await api.update(record: original, changes: ["title": .string("edited")], token: "sample") }
        #expect(posts == 1)
    }

    @MainActor @Test func demoEditsPersistInDetailsAndList() async throws {
        let store = TodayStore(isDemo: true)
        await store.restore()
        let item = store.today[0]
        let record = try await store.record(for: item)
        #expect(await store.saveTask(record: record, changes: ["title": .string("edited"), "content": .string("new text")]))
        #expect(store.today[0].task.title == "edited")
        let edited = try await store.record(for: store.today[0])
        #expect(edited.fields["content"]?.string == "new text")
        #expect(edited.fields["items"] == record.fields["items"])
        #expect(edited.fields["dueDate"] == record.fields["dueDate"])
        await store.refresh()
        #expect(store.today[0].task.title == "edited")
    }
}
