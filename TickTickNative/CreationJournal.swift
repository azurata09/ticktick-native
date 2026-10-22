import Foundation

nonisolated struct PendingCreation: Codable, Sendable {
    let title: String
    let projectID: String
    let date: Date
    var serverID: String? = nil
}

nonisolated struct CreationJournal: Sendable {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TickTickNative/pending-creation.json")
    }

    func load() throws -> PendingCreation? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PendingCreation.self, from: Data(contentsOf: url))
    }

    func save(_ pending: PendingCreation) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(pending).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
