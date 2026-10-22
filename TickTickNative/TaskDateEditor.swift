import SwiftUI

struct TaskDateEditor: View {
    let record: TaskRecord
    @Bindable var store: TodayStore
    @Environment(\.dismiss) private var dismiss
    @State private var dates: TaskDates?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("予定日時を変更").font(.title2)
            if let error { Text(error).foregroundStyle(.red) }
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
            if dates != nil {
                Toggle("日付を指定する", isOn: Binding(get: { dates!.hasDate }, set: { dates!.hasDate = $0 }))
                if dates!.hasDate {
                    Toggle("終日", isOn: Binding(get: { dates!.allDay }, set: { dates!.allDay = $0 }))
                    DatePicker("開始", selection: Binding(get: { dates!.start }, set: { dates!.start = $0 }),
                               displayedComponents: dates!.allDay ? [.date] : [.date, .hourAndMinute])
                    DatePicker("終了・期限", selection: Binding(get: { dates!.end }, set: { dates!.end = $0 }),
                               displayedComponents: dates!.allDay ? [.date] : [.date, .hourAndMinute])
                    Text("日時はこのMacのタイムゾーン（\(TimeZone.current.identifier)）で指定します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    guard let dates else { return }
                    do {
                        let changes = try dates.changes(repeating: record.fields["repeatFlag"]?.string?.isEmpty == false)
                        Task { if await store.saveTask(record: record, changes: changes) { dismiss() } }
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(dates == nil)
            }
        }.disabled(store.isSavingTask).padding(24).frame(width: 520)
            .interactiveDismissDisabled(store.isSavingTask)
            .task {
                do { dates = try TaskDates(task: record.task()) }
                catch { self.error = error.localizedDescription }
            }
    }
}
