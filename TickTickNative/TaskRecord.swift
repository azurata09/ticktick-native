import Foundation

nonisolated indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String), integer(Int64), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Int64.self) { self = .integer(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}

nonisolated struct TaskRecord: Codable, Equatable, Sendable {
    var fields: [String: JSONValue]

    init(fields: [String: JSONValue]) { self.fields = fields }

    init(from decoder: Decoder) throws {
        fields = try [String: JSONValue](from: decoder)
        guard fields["id"]?.string?.isEmpty == false,
              fields["projectId"]?.string?.isEmpty == false else { throw TickTickError.invalidResponse }
    }

    func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }

    func task() throws -> TickTask { try JSONDecoder().decode(TickTask.self, from: JSONEncoder().encode(self)) }

    func confirms(_ changes: [String: JSONValue]) -> Bool {
        changes.allSatisfy { key, expected in
            let actual = fields[key]
            if key == "repeatFlag", let requested = expected.string, let requestedRule = SimpleRecurrence.matching(requested) {
                switch actual {
                case nil, .null: return requestedRule == .none
                case .string(let value): return SimpleRecurrence.matching(value) == requestedRule
                default: return false
                }
            }
            let optionalText: Set<String> = ["content", "desc", "repeatFlag", "parentId"]
            let optionalLists: Set<String> = ["tags", "reminders", "items"]
            if actual == nil || actual == .null {
                if optionalText.contains(key), expected == .string("") { return true }
                if optionalLists.contains(key), expected == .array([]) { return true }
            }
            if expected == .null { return fields[key] == nil || fields[key] == .null }
            if key == "startDate" || key == "dueDate", let before = expected.string, let after = fields[key]?.string {
                let schedule = TaskSchedule(calendar: .current)
                let allDay = fields["isAllDay"] == .bool(true)
                if let a = schedule.date(before, allDay: allDay), let b = schedule.date(after, allDay: allDay) { return a == b }
            }
            return fields[key] == expected
        }
    }

    func changedUnrequestedFields(from original: TaskRecord, changes: [String: JSONValue]) -> [String] {
        let metadata: Set<String> = ["etag", "etimestamp", "modifiedTime", "completedTime", "focusSummaries"]
        let unchanged = original.fields.filter { !changes.keys.contains($0.key) && !metadata.contains($0.key) }
        return unchanged.compactMap { key, value in confirms([key: value]) ? nil : key }.sorted()
    }

    func preservesUnchangedFields(from original: TaskRecord, changes: [String: JSONValue]) -> Bool {
        changedUnrequestedFields(from: original, changes: changes).isEmpty
    }

    func updating(_ changes: [String: JSONValue]) throws -> [String: JSONValue] {
        let writable: Set<String> = ["id", "projectId", "title", "content", "desc", "isAllDay", "startDate", "dueDate",
                                     "timeZone", "reminders", "tags", "repeatFlag", "repeatFrom", "priority", "sortOrder", "items"]
        let readOnly: Set<String> = ["status", "completedTime", "kind", "etag", "focusSummaries", "parentId", "assigneeUsername", "etimestamp", "modifiedTime", "createdTime", "isFloating"]
        let unknown = Set(fields.keys).subtracting(writable.union(readOnly))
        guard unknown.isEmpty else { throw TickTickError.unsupportedTaskAttributes(Array(unknown)) }
        // isFloating は公開更新パラメータにない。無効な場合のみ編集し、再取得でも保持を照合する。
        if let floating = fields["isFloating"], floating != .null, floating != .bool(false) {
            throw TickTickError.unsupportedFloatingTime
        }
        guard Set(changes.keys).isSubset(of: writable.subtracting(["id", "projectId"])),
              fields["parentId"]?.string?.isEmpty != false else { throw TickTickError.unsupportedFields }
        var body = fields.filter { writable.contains($0.key) }
        body.merge(changes) { _, new in new }
        return body
    }
}

nonisolated enum SimpleRecurrence: String, CaseIterable, Identifiable {
    case none = "繰り返さない", daily = "毎日", weekly = "毎週"
    var id: String { rawValue }
    var rule: String {
        switch self {
        case .none: ""
        case .daily: "RRULE:FREQ=DAILY;INTERVAL=1"
        case .weekly: "RRULE:FREQ=WEEKLY;INTERVAL=1"
        }
    }
    static func matching(_ rule: String?) -> SimpleRecurrence? {
        guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return SimpleRecurrence.none }
        var raw = rule.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if raw.hasPrefix("RRULE:") { raw.removeFirst(6) }
        var parts: [String: String] = [:]
        for part in raw.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, parts[String(pair[0])] == nil else { return nil }
            parts[String(pair[0])] = String(pair[1])
        }
        guard let frequency = parts.removeValue(forKey: "FREQ"),
              frequency == "DAILY" || frequency == "WEEKLY" else { return nil }
        if let interval = parts.removeValue(forKey: "INTERVAL"), Int(interval) != 1 { return nil }
        if let weekStart = parts.removeValue(forKey: "WKST"), !["MO", "TU", "WE", "TH", "FR", "SA", "SU"].contains(weekStart) { return nil }
        guard parts.isEmpty else { return nil }
        return frequency == "DAILY" ? .daily : .weekly
    }
}
