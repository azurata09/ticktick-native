import Foundation
import Testing
@testable import TickTickNative

extension APITests {
    @Test func normalizedRecurrenceCanBeEnabledAndClearedWithoutFalseFailure() async throws {
        var fields: [String: JSONValue] = ["id": .string("t"), "projectId": .string("p"), "title": .string("sample")]
        var posts = 0
        let api = api { request in
            if request.httpMethod == "POST" {
                posts += 1
                if posts == 1 { fields["repeatFlag"] = .string("RRULE:FREQ=DAILY") }
                else { fields.removeValue(forKey: "repeatFlag") }
                return (200, Data())
            }
            return (200, try JSONEncoder().encode(fields))
        }
        let enabled = try await api.update(record: TaskRecord(fields: fields), changes: ["repeatFlag": .string(SimpleRecurrence.daily.rule)], token: "sample")
        _ = try await api.update(record: enabled, changes: ["repeatFlag": .string(SimpleRecurrence.daily.rule)], token: "sample")
        #expect(posts == 1)
        let cleared = try await api.update(record: enabled, changes: ["repeatFlag": .string("")], token: "sample")
        #expect(cleared.fields["repeatFlag"] == nil)
        #expect(posts == 2)
    }

    @Test func equivalentDailyRulesAndClearedRulesMatch() {
        for rule in ["RRULE:FREQ=DAILY", "RRULE:INTERVAL=1;FREQ=DAILY", "FREQ=DAILY;INTERVAL=1;WKST=MO"] {
            let returned = TaskRecord(fields: ["repeatFlag": .string(rule)])
            #expect(returned.confirms(["repeatFlag": .string(SimpleRecurrence.daily.rule)]))
        }
        #expect(TaskRecord(fields: [:]).confirms(["repeatFlag": .string("")]))
        #expect(TaskRecord(fields: ["repeatFlag": .null]).confirms(["repeatFlag": .string("")]))
        #expect(!TaskRecord(fields: ["repeatFlag": .string("RRULE:FREQ=DAILY;INTERVAL=2")]).confirms(["repeatFlag": .string(SimpleRecurrence.daily.rule)]))
        #expect(SimpleRecurrence.matching("RRULE:FREQ=DAILY;COUNT=10") == nil)
        #expect(SimpleRecurrence.matching("RRULE:FREQ=DAILY;INTERVAL=1;INTERVAL=2") == nil)
    }

    @Test func omittedEmptyOptionalFieldsDoNotMeanDataWasLost() {
        let returned = TaskRecord(fields: ["id": .string("t"), "projectId": .string("p"), "title": .string("sample")])
        #expect(returned.confirms(["content": .string(""), "desc": .string(""), "tags": .array([]), "items": .array([]), "parentId": .string("")]))
        #expect(!returned.confirms(["content": .string("text")]))
        #expect(!returned.confirms(["tags": .array([.string("work")])]))
    }

    @Test func responseMetadataIsNotSentAndFloatingFalseIsPreserved() async throws {
        var fields: [String: JSONValue] = ["id": .string("t"), "projectId": .string("p"), "title": .string("sample"),
            "createdTime": .string("2026-10-20T00:00:00Z"), "isFloating": .bool(false), "modifiedTime": .string("2026-10-23T00:00:00Z"), "etimestamp": .integer(123), "etag": .string("before")]
        let original = TaskRecord(fields: fields)
        let body = try original.updating(["repeatFlag": .string(SimpleRecurrence.daily.rule)])
        #expect(body["createdTime"] == nil)
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
        #expect(saved.fields["createdTime"] == original.fields["createdTime"])
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
