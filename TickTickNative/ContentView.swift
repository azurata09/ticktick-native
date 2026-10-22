import SwiftUI

struct ContentView: View {
    @State private var store = TodayStore(isDemo: ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.environment["TICKTICK_TESTING"] == "1")
    @State private var showsWeek = false
    @State private var showsConnection = false
    @State private var showsCreate = false
    @State private var confirmsResolution = false
    @State private var confirmsCompletionResolution = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(showsWeek ? "7日間" : "今日").font(.largeTitle.bold())
                    Text(Date.now, format: .dateTime.year().month().day().weekday())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isConnected || store.isDemo {
                    Picker("表示", selection: $showsWeek) {
                        Text("今日").tag(false)
                        Text("7日間").tag(true)
                    }.pickerStyle(.segmented).frame(width: 180)
                }
                if store.isLoading { ProgressView().controlSize(.small) }
                if store.isDemo {
                    Text("サンプル表示").foregroundStyle(.secondary)
                } else if store.isConnected {
                    Text(store.canWrite ? "読み書き接続" : "読み取り専用").foregroundStyle(.secondary)
                }
            }
            .padding(24)

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }

            if let message = store.operationMessage {
                Text(message).foregroundStyle(.secondary).padding(.horizontal, 24)
            }
            if let reminderMessage = store.reminderMessage {
                Text(reminderMessage).foregroundStyle(.orange).padding(.horizontal, 24)
            }
            if store.pendingCreation != nil || store.creationRecordError {
                VStack(alignment: .leading) {
                    Text("結果未確認の追加記録があります。TickTickで保存先を確認してください。再送は停止しています。")
                    Button("確認後に追加記録を解除…") { confirmsResolution = true }.disabled(store.isSavingTask)
                }.padding(.horizontal, 24)
            }
            if !store.pendingCompletions.isEmpty || store.completionRecordError {
                Button("TickTickで確認後に完了記録を解除…") { confirmsCompletionResolution = true }
                    .disabled(store.isSavingTask).padding(.horizontal, 24)
                Text("結果未確認の完了記録があります。更新でサーバーの状態を確認し、確認できるまで再送しません。")
                    .foregroundStyle(.orange).padding(.horizontal, 24)
            }
            if store.isConnected || store.isDemo {
                taskList
                coverage
            } else {
                ContentUnavailableView {
                    Label("TickTickに接続", systemImage: "checklist")
                } description: {
                    Text("今日の予定と期限切れの作業を、ひとつの画面で確認できます。")
                } actions: {
                    Button("接続を設定…") { showsConnection = true }
                        .buttonStyle(.borderedProminent)
                }
                Spacer(minLength: 20)
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .toolbar {
            if store.isConnected || store.isDemo {
                Button { showsCreate = true } label: { Label("タスクを追加", systemImage: "plus") }
                    .keyboardShortcut("n")
                    .disabled(!store.canWrite || store.isSavingTask || store.isLoading || store.pendingCreation != nil || store.creationRecordError || store.needsAuthorization)
                Button { Task { await store.refresh() } } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(store.isLoading || store.isSavingTask || store.needsAuthorization)
            }
            if !store.isDemo {
                Button(store.needsAuthorization ? "接続し直す…" : "接続設定…") { showsConnection = true }
            }
        }
        .sheet(isPresented: $showsConnection) { ConnectionView(store: store) }
        .sheet(isPresented: $showsCreate) { CreateTaskView(store: store) }
        .confirmationDialog("保存結果をTickTickで確認しましたか？記録の解除はタスクを再送しません。", isPresented: $confirmsResolution) {
            Button("確認済みとして記録を解除") { store.resolvePendingCreation() }
        }
        .confirmationDialog("TickTickで次回予定または完了状態を確認しましたか？解除後の完了操作は、次回分を完了する可能性があります。", isPresented: $confirmsCompletionResolution) {
            Button("確認済みとして完了記録を解除") { store.resolvePendingCompletions() }
        }
        .task { await store.restore() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in Task { await store.regroup() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in Task { await store.regroup() } }
    }

    @ViewBuilder
    private var taskList: some View {
        if store.isLoading && store.updatedAt == nil {
            VStack { Spacer(); ProgressView("予定を取得しています…"); Spacer() }
                .frame(maxWidth: .infinity)
        } else if showsWeek && store.updatedAt != nil {
            List {
                ForEach(store.week) { day in
                    Section(day.date.formatted(.dateTime.month().day().weekday()) + " · \(day.tasks.count)件") {
                        ForEach(day.tasks) { TaskRow(item: $0, overdue: false, store: store) }
                        if day.tasks.isEmpty { Text("予定はありません").foregroundStyle(.secondary) }
                    }
                }
            }.listStyle(.inset)
        } else if store.today.isEmpty && store.overdue.isEmpty {
            ContentUnavailableView {
                Label(store.updatedAt == nil ? "予定を取得できませんでした" : "表示できるタスクはありません", systemImage: "calendar")
            } description: {
                Text("取得範囲と通信状態は、画面下の案内を確認してください。")
            }
        } else {
            List {
                if !store.overdue.isEmpty {
                    Section("期限切れ · \(store.overdue.count)件") {
                        ForEach(store.overdue) { TaskRow(item: $0, overdue: true, store: store) }
                    }
                }
                Section("今日の予定 · \(store.today.count)件") {
                    ForEach(store.today) { TaskRow(item: $0, overdue: false, store: store) }
                    if store.today.isEmpty { Text("今日の予定はありません").foregroundStyle(.secondary) }
                }
            }
            .listStyle(.inset)
        }
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsWeek { Text("期間のある予定は、7日間のうち最初に重なる日に1回表示します。期限切れは「今日」で確認できます。") }
            if store.isDemo {
                Text("サンプルデータです。APIへの接続やKeychainへの保存は行いません。")
            } else {
                Text("取得済み：\(store.projectCount)件の未アーカイブのリスト。受信箱は対象外です（取得方法未確認）。")
                if let date = store.updatedAt {
                    Text("取得時刻：\(date.formatted(date: .omitted, time: .standard))。更新に失敗した場合は前回の内容を表示します。")
                }
            }
            ForEach(Array(store.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.bar)
    }
}

private struct TaskRow: View {
    let item: ListedTask
    let overdue: Bool
    @Bindable var store: TodayStore
    @State private var showsRecurrence = false
    @State private var showsReminder = false
    @State private var showsDetail = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                Task { _ = await store.completeTask(item) }
            } label: {
                Image(systemName: "circle").foregroundStyle(overdue ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("完了にする：" + item.task.title)
            .disabled(!store.canWrite || store.isSavingTask || store.isLoading || store.needsAuthorization || SimpleRecurrence.matching(item.task.repeatFlag) == nil || store.completionRecordError || store.pendingCompletions.contains { $0.taskID == item.task.id && $0.projectID == item.task.projectId })
            .help("タスクを完了にする")
            VStack(alignment: .leading, spacing: 5) {
                Text(item.task.title).textSelection(.enabled)
                HStack {
                    Text(item.projectName)
                    if let raw = item.task.startDate, raw != item.task.dueDate,
                       let start = TaskSchedule(calendar: .current).date(raw, allDay: item.task.isAllDay == true) {
                        Text(start, format: item.task.isAllDay == true ? .dateTime.month().day() : .dateTime.month().day().hour().minute())
                        Text("〜")
                    }
                    if let raw = item.task.dueDate ?? item.task.startDate,
                       let date = TaskSchedule(calendar: .current).date(raw, allDay: item.task.isAllDay == true) {
                        Text(date, format: item.task.isAllDay == true
                             ? .dateTime.month().day()
                             : .dateTime.month().day().hour().minute())
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button("詳細を表示…") { showsDetail = true }
            Button("このMacの通知…") { showsReminder = true }.disabled(store.isDemo)
            Button("繰り返しと開始予定…") { showsRecurrence = true }.disabled(!store.canWrite || store.isDemo)
        }
        .sheet(isPresented: $showsRecurrence) { RecurrenceView(item: item, store: store) }
        .sheet(isPresented: $showsReminder) { ReminderView(item: item, store: store) }
        .sheet(isPresented: $showsDetail) { TaskDetailView(item: item, store: store) }
    }
}

private struct ConnectionView: View {
    @Bindable var store: TodayStore
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var secret = ""
    @State private var allowWrite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("TickTickへの接続").font(.title2.bold())
            Text("個人用アプリのClient IDとClient Secretを入力してください。認証情報はこのMacのKeychainに保存します。")
            Link("開発者ポータルを開く", destination: URL(string: "https://developer.ticktick.com/manage")!)
            Text("登録するリダイレクトURL")
            Text(OAuthFlow.redirectURI).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            TextField("Client ID", text: $clientID)
                .textFieldStyle(.roundedBorder).disableAutocorrection(true)
            SecureField("Client Secret", text: $secret).textFieldStyle(.roundedBorder)
            Toggle("タスクの作成と更新を許可する", isOn: $allowWrite)
            Text(allowWrite ? "読み取りと書き込みの権限を要求します。操作したタスクだけを変更します。" : "読み取り専用で接続します。追加や変更には書き込み権限での再認証が必要です。")
                .font(.callout).foregroundStyle(.secondary)
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Button("このMacの接続を解除", role: .destructive) {
                    store.disconnect()
                    if store.errorMessage == nil { dismiss() }
                }
                Spacer()
                Button(store.isAuthorizing ? "認証をキャンセル" : "閉じる") {
                    store.cancelAuthorization()
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                Button(store.isAuthorizing ? "認証中…" : "ブラウザで認証") {
                    let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = secret
                    Task {
                        await store.connect(clientID: id, secret: value, allowWrite: allowWrite)
                        if store.isConnected && !store.needsAuthorization && store.errorMessage == nil {
                            secret = ""
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || secret.isEmpty || store.isAuthorizing || store.isLoading)
            }
        }
        .padding(28).frame(width: 560)
        .onAppear {
            clientID = store.savedClientID
            secret = store.savedClientSecret
            allowWrite = store.canWrite
        }
    }
}

private struct CreateTaskView: View {
    @Bindable var store: TodayStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var projectID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("今日やることを追加").font(.title2.bold())
            TextField("タスクのタイトル", text: $title).textFieldStyle(.roundedBorder)
            Picker("保存先", selection: $projectID) {
                Text("リストを選択").tag("")
                ForEach(store.writableProjects, id: \.id) { Text($0.name).tag($0.id) }
            }
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
            if store.pendingCreation != nil {
                Text("保存結果を確認するまで再送できません。画面を閉じ、TickTickで確認してください。")
            }
            HStack {
                Button("キャンセル") { dismiss() }.disabled(store.isSavingTask).keyboardShortcut(.cancelAction)
                Spacer()
                Button(store.isSavingTask ? "保存中…" : "追加") {
                    Task { if await store.createTask(title: title, projectID: projectID) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || projectID.isEmpty || store.isSavingTask || store.pendingCreation != nil)
            }
        }.padding(24).frame(width: 480)
        .interactiveDismissDisabled(store.isSavingTask)
        .onAppear { projectID = store.writableProjects.first?.id ?? "" }
    }
}

private struct RecurrenceView: View {
    let item: ListedTask
    @Bindable var store: TodayStore
    @Environment(\.dismiss) private var dismiss
    @State private var record: TaskRecord?
    @State private var date = Date.now
    @State private var allDay = true
    @State private var recurrence = SimpleRecurrence.none
    @State private var error: String?
    @State private var supported = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("繰り返しと開始予定").font(.title2)
            Text(item.task.title)
            if let error { Text(error).foregroundStyle(.red) }
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
            if record != nil {
                DatePicker("開始予定", selection: $date, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                Toggle("終日", isOn: $allDay)
                Picker("繰り返し", selection: $recurrence) {
                    ForEach(SimpleRecurrence.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("開始と終了を同じ日時に設定します。次回予定はTickTickで生成されます。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if error == nil { ProgressView() }
            HStack {
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    guard let record else { return }
                    Task { if await store.saveRecurrence(record: record, date: date, allDay: allDay, recurrence: recurrence) { dismiss() } }
                }.keyboardShortcut(.defaultAction)
                    .disabled(record == nil || !supported || store.isSavingTask)
            }
        }.padding(24).frame(width: 480)
            .interactiveDismissDisabled(store.isSavingTask)
            .task {
                do {
                    let loaded = try await store.record(for: item)
                    record = loaded
                    let task = try loaded.task()
                    if let value = SimpleRecurrence.matching(task.repeatFlag) { recurrence = value; supported = true }
                    else { error = "既存の繰り返しルールは未対応です。変更せず保持します。" }
                    allDay = task.isAllDay == true
                    if let raw = task.startDate ?? task.dueDate,
                       let parsed = TaskSchedule(calendar: .current).date(raw, allDay: allDay) { date = parsed }
                } catch { self.error = error.localizedDescription }
            }
    }
}

private struct ReminderView: View {
    let item: ListedTask
    @Bindable var store: TodayStore
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date.now.addingTimeInterval(300)
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("このMacの通知").font(.title2)
            Text(item.task.title)
            DatePicker("通知時刻", selection: $date, displayedComponents: [.date, .hourAndMinute])
            Text("このMacだけの設定です。TickTickのリマインダーは変更しません。公式アプリの通知も有効な場合、両方から通知されます。繰り返しでは開始予定からの時間差を引き継ぎます。")
                .font(.callout).foregroundStyle(.secondary)
            Text("予約済みの通知はアプリ終了中もOSが配信します。スリープ中の即時配信や、終了中の他端末の変更反映は保証されません。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = store.reminderMessage { Text(message).foregroundStyle(.red) }
            HStack {
                Button("通知を解除") { save(nil) }
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("設定") { save(date) }.keyboardShortcut(.defaultAction)
            }.disabled(saving)
        }.padding(24).frame(width: 480).interactiveDismissDisabled(saving)
    }
    private func save(_ date: Date?) {
        saving = true
        Task {
            if await store.setReminder(for: item, date: date) { dismiss() }
            saving = false
        }
    }
}
