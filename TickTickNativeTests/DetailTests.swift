import Foundation
import Testing
@testable import TickTickNative

extension APITests {
    @Test func detailIsReadOnlyAndKeepsUnknownInformation() async throws {
        let api = api { request in
            #expect(request.httpMethod == "GET")
            return (200, Data(#"{"id":"t","projectId":"p","title":"sample","content":"long description","items":[{"id":"i","title":"step","status":1}],"futureProperty":{"enabled":true}}"#.utf8))
        }
        let record = try await api.record(projectID: "p", taskID: "t", token: "sample")
        #expect(record.fields["content"]?.string == "long description")
        #expect(record.fields["items"]?.array?.count == 1)
        #expect(record.fields["futureProperty"] != nil)
    }

    @Test func detailRejectsMismatchedIdentity() async {
        let api = api { _ in (200, Data(#"{"id":"other","projectId":"p","title":"sample"}"#.utf8)) }
        await #expect(throws: TickTickError.self) { try await api.record(projectID: "p", taskID: "t", token: "sample") }
    }
}
