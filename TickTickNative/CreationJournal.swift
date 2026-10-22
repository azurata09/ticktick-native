import Foundation

nonisolated struct PendingCreation: Codable, Sendable {
    let title: String
    let projectID: String
    let date: Date
    var serverID: String? = nil
}

nonisolated struct CompletionReceipt: Codable, Sendable {
    let taskID: String
    let projectID: String
    let previousDue: String?
}

typealias CreationJournal = FileJournal<PendingCreation>
typealias CompletionJournal = FileJournal<[CompletionReceipt]>

nonisolated struct FileJournal<Value: Codable & Sendable>: Sendable {
    let url: URL

    init(url: URL? = nil, filename: String = "pending-creation.json") {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TickTickNative/" + filename)
    }

    func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    func save(_ pending: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(pending).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
