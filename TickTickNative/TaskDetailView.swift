import SwiftUI

struct TaskDetailView: View {
    let item: ListedTask
    @Bindable var store: TodayStore
    @Environment(\.dismiss) private var dismiss
    @State private var record: TaskRecord?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("タスクの詳細").font(.title2)
            if let error {
                Text(error).foregroundStyle(.red)
                Button("再読み込み") { Task { await load() } }
            } else if let record {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(record.fields["title"]?.string ?? item.task.title).font(.title2.bold())
                        Text(item.projectName).foregroundStyle(.secondary)
                        detail("本文", value: record.fields["content"])
                        detail("説明", value: record.fields["desc"])
                        dateDetail("開始", key: "startDate", record: record)
                        dateDetail("終了・期限", key: "dueDate", record: record)
                        detail("終日", value: record.fields["isAllDay"])
                        detail("タイムゾーン", value: record.fields["timeZone"])
                        detail("優先度（0:なし / 1:低 / 3:中 / 5:高）", value: record.fields["priority"])
                        detail("繰り返し", value: record.fields["repeatFlag"])
                        if let items = record.fields["items"]?.array, !items.isEmpty {
                            Text("チェック項目").font(.headline)
                            ForEach(Array(items.enumerated()), id: \.offset) { _, value in
                                if case .object(let fields) = value {
                                    Label(fields["title"]?.string ?? "名称なし", systemImage: fields["status"] == .integer(1) ? "checkmark.square" : "square")
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            } else { ProgressView("詳細を取得しています…").frame(maxWidth: .infinity) }
            HStack { Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 600, height: 560).task { await load() }
    }

    @ViewBuilder private func dateDetail(_ label: String, key: String, record: TaskRecord) -> some View {
        if let raw = record.fields[key]?.string {
            if let date = TaskSchedule(calendar: .current).date(raw, allDay: record.fields["isAllDay"] == .bool(true)) {
                detail(label, value: .string(date.formatted(date: .abbreviated, time: record.fields["isAllDay"] == .bool(true) ? .omitted : .shortened)))
            } else { detail(label, value: .string(raw)) }
        }
    }

    @ViewBuilder private func detail(_ label: String, value: JSONValue?) -> some View {
        if let value, value != .null {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.headline)
                Text(value.string ?? String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self))
            }
        }
    }

    private func load() async {
        error = nil
        do { record = try await store.record(for: item) }
        catch { self.error = error.localizedDescription }
    }
}
