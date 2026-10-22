import Foundation
import Testing
@testable import TickTickNative

extension APITests {
    @Test func responseMetadataIsNotSentAndFloatingFalseIsPreserved() async throws {
        var fields: [String: JSONValue] = ["id": .string("t"), "projectId": .string("p"), "title": .string("sample"),
            "isFloating": .bool(false), "modifiedTime": .string("2026-10-23T00:00:00Z"), "etimestamp": .integer(123), "etag": .string("before")]
        let original = TaskRecord(fields: fields)
        let body = try original.updating(["repeatFlag": .string(SimpleRecurrence.daily.rule)])
        #expect(body["isFloating"] == nil)
        #expect(body["modifiedTime"] == nil)
        #expect(body["etimestamp"] == nil)
        let api = api { request in
            if request.httpMethod == "POST" {
                fields["repeatFlag"] = .string(SimpleRecurrence.daily.rule)
                fields["modifiedTime"] = .string("2026-10-23T00:01:00Z")
                fields["etimestamp"] = .integer(456)
                fields["etag"] = .string("after")
                return (200, Data())
            }
            return (200, try JSONEncoder().encode(fields))
        }
        let saved = try await api.update(record: original, changes: ["repeatFlag": .string(SimpleRecurrence.daily.rule)], token: "sample")
        #expect(saved.fields["isFloating"] == .bool(false))
    }

    @Test func floatingTimeAndUnexpectedAttributeLossAreNotIgnored() throws {
        let original = TaskRecord(fields: ["id": .string("t"), "projectId": .string("p"), "title": .string("sample"), "isFloating": .bool(true)])
        #expect(throws: TickTickError.self) { try original.updating(["repeatFlag": .string(SimpleRecurrence.daily.rule)]) }
        var before = original
        before.fields["isFloating"] = .bool(false)
        var after = before
        after.fields["isFloating"] = .bool(true)
        #expect(!after.preservesUnchangedFields(from: before, changes: [:]))
    }
}
