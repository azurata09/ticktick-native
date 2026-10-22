import SwiftUI

struct ContentView: View {
    @State private var store = TodayStore(isDemo: ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.environment["TICKTICK_TESTING"] == "1")
    @State private var showsConnection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("今日").font(.largeTitle.bold())
                    Text(Date.now, format: .dateTime.year().month().day().weekday())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                if store.isDemo {
                    Text("サンプル表示").foregroundStyle(.secondary)
                } else if store.isConnected {
                    Text("読み取り専用").foregroundStyle(.secondary)
                }
            }
            .padding(24)

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24).padding(.bottom, 12)
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
                Button { Task { await store.refresh() } } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .disabled(store.isLoading || store.needsAuthorization)
            }
            if !store.isDemo {
                Button(store.needsAuthorization ? "接続し直す…" : "接続設定…") { showsConnection = true }
            }
        }
        .sheet(isPresented: $showsConnection) { ConnectionView(store: store) }
        .task { await store.restore() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in Task { await store.regroup() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in Task { await store.regroup() } }
    }

    @ViewBuilder
    private var taskList: some View {
        if store.isLoading && store.updatedAt == nil {
            VStack { Spacer(); ProgressView("予定を取得しています…"); Spacer() }
                .frame(maxWidth: .infinity)
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
                        ForEach(store.overdue) { TaskRow(item: $0, overdue: true) }
                    }
                }
                Section("今日の予定 · \(store.today.count)件") {
                    ForEach(store.today) { TaskRow(item: $0, overdue: false) }
                    if store.today.isEmpty { Text("今日の予定はありません").foregroundStyle(.secondary) }
                }
            }
            .listStyle(.inset)
        }
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: 6) {
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: overdue ? "clock.badge.exclamationmark" : "circle")
                .foregroundStyle(overdue ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.task.title).textSelection(.enabled)
                HStack {
                    Text(item.projectName)
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
    }
}

private struct ConnectionView: View {
    @Bindable var store: TodayStore
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var secret = ""

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
            Text("ブラウザで認証すると、リストとタスクを読み取ります。タスクの追加、変更、削除は行いません。")
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
                        await store.connect(clientID: id, secret: value)
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
        }
    }
}
