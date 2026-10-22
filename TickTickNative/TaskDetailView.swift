import SwiftUI

struct TaskDetailView: View {
    let item: ListedTask
    @Bindable var store: TodayStore
    @Environment(\.dismiss) private var dismiss
    @State private var record: TaskRecord?
    @State private var error: String?
    @State private var showsEditor = false
    @State private var showsDates = false

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
            HStack {
                Button("内容を編集…") { showsEditor = true }.disabled(record == nil || !store.canWrite || store.isSavingTask)
                Button("予定日時…") { showsDates = true }.disabled(record == nil || !store.canWrite || store.isSavingTask)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 600, height: 560).task { await load() }
            .sheet(isPresented: $showsEditor, onDismiss: { Task { await load() } }) {
                if let record { TaskTextEditor(record: record, store: store) }
            }
            .sheet(isPresented: $showsDates, onDismiss: { Task { await load() } }) {
                if let record { TaskDateEditor(record: record, store: store) }
            }
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

private struct TaskTextEditor: View {
    let record: TaskRecord
    @Bindable var store: TodayStore
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var content: String

    init(record: TaskRecord, store: TodayStore) {
        self.record = record
        self.store = store
        _title = State(initialValue: record.fields["title"]?.string ?? "")
        _content = State(initialValue: record.fields["content"]?.string ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("タスクの内容を編集").font(.title2)
            TextField("タイトル", text: $title).textFieldStyle(.roundedBorder).disabled(store.isSavingTask)
            Text("本文").font(.headline)
            TextEditor(text: $content).accessibilityLabel("本文").border(.secondary.opacity(0.3)).disabled(store.isSavingTask)
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    Task {
                        if await store.saveTask(record: record, changes: ["title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)), "content": .string(content)]) { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(store.isSavingTask)
        }.padding(24).frame(width: 560, height: 460).interactiveDismissDisabled(store.isSavingTask)
    }
}
