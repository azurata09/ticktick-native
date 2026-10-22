import Foundation
import Testing
@testable import TickTickNative

extension APITests {
    @Test func recurrenceUpdatePreservesOtherValues() async throws {
        var fields: [String: JSONValue] = ["id": .string("t"), "projectId": .string("p"), "title": .string("sample"),
            "content": .string("description"), "tags": .array([.string("work")]), "sortOrder": .integer(9007199254740993),
            "items": .array([.object(["id": .string("i"), "title": .string("step"), "status": .integer(0)])])]
        let record = TaskRecord(fields: fields)
        var posts = 0
        let api = api { request in
            if request.httpMethod == "POST" {
                posts += 1
                var data = request.httpBody ?? Data()
                if data.isEmpty, let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(buffer, count: count)
                    }
                }
                let body = try JSONDecoder().decode([String: JSONValue].self, from: data)
                #expect(body["content"] == fields["content"])
                #expect(body["items"] == fields["items"])
                #expect(body["sortOrder"] == .integer(9007199254740993))
                fields = body
                return (200, Data())
            }
            return (200, try JSONEncoder().encode(fields))
        }
        let updated = try await api.update(record: record, changes: ["repeatFlag": .string(SimpleRecurrence.daily.rule)], token: "sample")
        #expect(updated.fields["repeatFlag"]?.string == SimpleRecurrence.daily.rule)
        #expect(posts == 1)
    }

    @Test func unknownFieldsAndConcurrentChangesStopUpdates() async throws {
        let record = TaskRecord(fields: ["id": .string("t"), "projectId": .string("p"), "title": .string("sample"), "futureProperty": .bool(true)])
        #expect(throws: TickTickError.self) { try record.updating(["repeatFlag": .string("")]) }
        let api = api { request in
            #expect(request.httpMethod == "GET")
            return (200, Data(#"{"id":"t","projectId":"p","title":"changed"}"#.utf8))
        }
        await #expect(throws: TickTickError.self) { try await api.update(record: record, changes: ["repeatFlag": .string("")], token: "sample") }
    }

    @Test func recurringCompletionUsesServerNextDate() async throws {
        var posts = 0
        let original = TickTask(id: "t", projectId: "p", title: "sample", isAllDay: true, dueDate: "2026-10-23T00:00:00+0900", repeatFlag: SimpleRecurrence.daily.rule)
        let api = api { request in
            if request.httpMethod == "POST" { posts += 1; return (200, Data()) }
            var task = original
            if posts > 0 { task.dueDate = "2026-10-24T00:00:00+0900" }
            return (200, try JSONEncoder().encode(task))
        }
        let confirmed = try await api.complete(projectID: "p", taskID: "t", token: "sample", expected: original)
        #expect(confirmed.dueDate == "2026-10-24T00:00:00+0900")
        await #expect(throws: TickTickError.self) { try await api.complete(projectID: "p", taskID: "t", token: "sample", expected: original) }
        #expect(posts == 1)
    }

    @MainActor @Test func uncertainRecurringCompletionRemainsBlockedAfterRestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = CompletionJournal(url: folder.appendingPathComponent("completion.json"))
        let creation = CreationJournal(url: folder.appendingPathComponent("creation.json"))
        let task = TickTask(id: "t", projectId: "p", title: "sample", dueDate: "2026-10-23T00:00:00Z", repeatFlag: SimpleRecurrence.daily.rule)
        var posts = 0
        let api = api { request in
            if request.httpMethod == "POST" { posts += 1; throw URLError(.timedOut) }
            if request.url!.path.hasSuffix("/project") { return (200, Data("[]".utf8)) }
            return (200, try JSONEncoder().encode(task))
        }
        let connection = TickConnection(clientID: "sample", clientSecret: "sample", accessToken: "sample", canWrite: true)
        let item = ListedTask(task: task, projectName: "sample")
        let store = TodayStore(api: api, initialConnection: connection, creationJournal: creation, completionJournal: journal)
        #expect(!(await store.completeTask(item)))
        let relaunched = TodayStore(api: api, initialConnection: connection, creationJournal: creation, completionJournal: journal)
        await relaunched.restore()
        #expect(!(await relaunched.completeTask(item)))
        #expect(posts == 1)
        #expect(try journal.load()?.count == 1)
    }
}
