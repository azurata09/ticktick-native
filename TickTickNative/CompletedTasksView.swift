import SwiftUI

struct CompletedTasksView: View {
    @Bindable var store: TodayStore
    @State private var start = Calendar.current.date(byAdding: .day, value: -6, to: .now)!
    @State private var end = Date.now
    @State private var records: [TaskRecord] = []
    @State private var isLoading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var selected: ListedTask?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DatePicker("開始日", selection: $start, displayedComponents: [.date])
                DatePicker("終了日", selection: $end, displayedComponents: [.date])
                Button("履歴を取得") { Task { await load() } }
            }.disabled(isLoading).padding(.horizontal, 24)
            Text("APIで取得できる完了タスクを、リストを指定せず検索します。最大200件のため、全件の実績とは限りません。")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24)
            if let error { Text(error).foregroundStyle(.red).padding(.horizontal, 24) }
            if isLoading { ProgressView("完了履歴を取得しています…").padding(.horizontal, 24) }
            if loaded && records.isEmpty && error == nil { Text("指定期間に取得できた完了タスクはありません").padding(24) }
            if records.count == 200 { Text("200件に達しています。期間を短くすると、ほかの完了タスクを取得できる場合があります。") .foregroundStyle(.orange).padding(.horizontal, 24) }
            List(Array(records.enumerated()), id: \.offset) { _, record in
                Button {
                    if let task = try? record.task() {
                        let name = store.projects.first { $0.id == task.projectId }?.name ?? "取得範囲外のリスト"
                        selected = ListedTask(task: task, projectName: name)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(record.fields["title"]?.string ?? "無題", systemImage: "checkmark.circle")
                        if let raw = record.fields["completedTime"]?.string,
                           let date = TaskSchedule(calendar: .current).date(raw, allDay: false) {
                            Text(date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }.buttonStyle(.plain)
            }.listStyle(.inset)
        }.task { await load() }
            .sheet(item: $selected) { TaskDetailView(item: $0, store: store) }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await store.completed(from: start, through: end)
            guard !Task.isCancelled else { return }
            records = result
            loaded = true
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }
}
