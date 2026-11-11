import SwiftUI
import Observation

/// 설정 창 사이드바 항목 (DESIGN.md 설정 창, T-011)
/// 로그인 시 자동 실행(T-010)은 '일반'에 있다
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, lms, alerts, history, storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "일반"
        case .lms: return "LMS 연동"
        case .alerts: return "알림"
        case .history: return "기록 보관"
        case .storage: return "저장 공간"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .lms: return "graduationcap"
        case .alerts: return "bell"
        case .history: return "clock.arrow.circlepath"
        case .storage: return "internaldrive"
        }
    }
}

/// 고른 사이드바 항목 (창 컨트롤러와 화면이 함께 씀)
@MainActor
@Observable
final class SettingsNavigation {
    var pane: SettingsPane = .general
}

/// 설정 창 내용: 왼쪽 사이드바 + 오른쪽 둥근 묶음 상자(행 = 제목 + 작은 설명, 오른쪽에 스위치·버튼)
struct SettingsView: View {
    static let size = CGSize(width: 720, height: 540)

    let sync: LmsSyncService
    let history: HistoryService
    let navigation: SettingsNavigation
    /// 노치 알림 (T-005). 없으면 알림 항목에 안내만
    let alerts: NotchAlertScheduler?
    let permissionCenter: LocalNotificationCenter?
    var updates: UpdateService? = nil
    let onCleanup: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 190)
                .frame(maxHeight: .infinity, alignment: .top)

            Rectangle().fill(Palette.separator).frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                Text(navigation.pane.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Palette.primaryText)
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                    .padding(.bottom, 2)
                if history.todoStore.saveError != nil || history.lmsStore.saveError != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("저장하지 못한 변경이 있어요. 앱을 종료하지 말고 다시 저장해 주세요.")
                            .font(.caption).foregroundStyle(Palette.overdue)
                        Button("저장 다시 시도") {
                            _ = history.todoStore.flushPendingSave()
                            _ = history.lmsStore.retryPendingSaves()
                        }
                    }.padding(.horizontal, 28).padding(.vertical, 8)
                }
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // 사이드바·제목·묶음 상자 바깥을 한 색으로: 패널과 같은 바탕 (밝은 = 흰색, 어두운 = 노치 검정)
        .background(Palette.panelBackground)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { pane in
                let selected = navigation.pane == pane
                Button { navigation.pane = pane } label: {
                    HStack(spacing: 8) {
                        Image(systemName: pane.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.todoAccent)
                            .frame(width: 20)
                        Text(pane.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(Palette.primaryText)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Palette.todoAccentSoft : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.pane {
        case .general: GeneralSettingsPane(updates: updates)
        case .lms: LmsSettingsPane(sync: sync)
        case .alerts:
            if let alerts {
                AlertSettingsPane(scheduler: alerts, center: permissionCenter)
            } else {
                Text("알림을 쓸 수 없어요").foregroundStyle(Palette.secondaryText).padding(28)
            }
        case .history: HistorySettingsPane(history: history, onCleanup: onCleanup, onReset: onReset)
        case .storage: StorageSettingsPane(history: history)
        }
    }
}

/// 행 제목 + 작은 설명
private struct RowLabel: View {
    let title: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(Palette.primaryText)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 일반

struct GeneralSettingsPane: View {
    var updates: UpdateService? = nil
    var loginItem: LoginItemService = MainAppLoginItem()
    /// 시스템에서 읽은 자동 실행 상태 (화면이 보일 때·앱이 앞으로 올 때·스위치를 바꾼 뒤 다시 읽는다. 저장하지 않음)
    @State private var loginDisplay = LoginItemDisplay(status: .notRegistered)
    @State private var loginError: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func refreshLoginItem() {
        loginDisplay = LoginItemDisplay(status: loginItem.status)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(version).monospacedDigit().foregroundStyle(Palette.secondaryText)
                } label: {
                    RowLabel(title: "버전", caption: "DoIt · 노치 할 일 목록")
                }
            }
            Section {
                Toggle(isOn: Binding(
                    get: { loginDisplay.isOn },
                    set: { on in
                        loginError = LoginItemAction.set(on, service: loginItem)
                        refreshLoginItem()
                    })) {
                    RowLabel(title: "로그인 시 자동 실행", caption: loginError ?? loginDisplay.caption)
                }
                if loginDisplay.showsOpenSettings {
                    Button("로그인 항목 열기…") { loginItem.openSystemSettings() }
                }
            }
            if let updates {
                Section {
                    Toggle(isOn: Binding(get: { updates.automaticallyChecksForUpdates },
                                         set: { updates.setAutomaticChecks($0) })) {
                        RowLabel(title: "자동으로 업데이트 확인", caption: "하루 간격으로 새 버전을 확인해요. 설치는 직접 선택해요.")
                    }
                    Button("업데이트 확인…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                    Text(updates.status).font(.caption).foregroundStyle(Palette.secondaryText)
                }
            }
        }
        .onAppear { refreshLoginItem() }
        // 시스템 설정에서 바꾸고 돌아왔을 때 (이벤트로만 다시 읽는다, 주기 확인 없음)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginItem()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)  // 창 전체를 패널과 같은 바탕색으로 (어두운 모드 = 노치 검정)
    }
}

// MARK: - LMS 연동 (T-007 기능 그대로)

struct LmsSettingsPane: View {
    let sync: LmsSyncService

    /// 입력 중인 주소 (저장하면 바로 비운다. 화면에도 보이지 않게 SecureField)
    @State private var urlInput = ""
    @State private var editingURL = false
    @State private var urlError: String?
    @State private var confirmingDisconnect = false

    private var store: LmsStore { sync.store }

    var body: some View {
        let availability = sync.manualAvailability(now: store.displayNow)

        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { store.isEnabled },
                    set: { on in
                        store.isEnabled = on
                        if on { sync.trigger(.enabled) }
                    })) {
                    RowLabel(title: "LMS 연동 켜기", caption: "학교 LMS 캘린더 피드에서 과제를 읽어 와요 (읽기만 해요)")
                }

                feedURLRow

                LabeledContent {
                    Stepper(value: Binding(get: { store.weeks }, set: { store.weeks = $0 }),
                            in: LmsDisplay.minWeeks...LmsDisplay.maxWeeks) {
                        Text("\(store.weeks)주").monospacedDigit().foregroundStyle(Palette.primaryText)
                    }
                } label: {
                    RowLabel(title: "가져올 기간", caption: "오늘부터 보여 줄 기간")
                }
            }

            Section {
                LabeledContent {
                    Text(lastSyncText).foregroundStyle(Palette.secondaryText)
                } label: {
                    RowLabel(title: "마지막 동기화")
                }
                LabeledContent {
                    Text(store.isSyncing ? "동기화 중…" : LmsDisplay.settingsStatus(record: store.record, now: store.displayNow))
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    RowLabel(title: "상태")
                }
                HStack {
                    Text("자동 새로 고침은 앱 실행·잠자기 해제·패널 펼침 때, 마지막 시도 후 6시간이 지났을 때만 해요. 수동은 5분에 1번까지.")
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Button("지금 새로고침") { sync.trigger(.manual) }
                            .disabled(!availability.enabled)
                        if let note = availability.note, store.isEnabled, store.hasFeedURL {
                            Text(note).font(.caption).foregroundStyle(Palette.secondaryText)
                        }
                    }
                }
            }

            if store.isDisconnectPending {
                Section {
                    Text("연결 해제를 마치지 못했어요. 동기화는 중단했으며, 저장된 주소나 캐시가 남아 있을 수 있어요.")
                        .font(.caption).foregroundStyle(Palette.overdue)
                    Button("연결 해제 다시 시도") { sync.disconnect() }
                }
            }
            if store.hasFeedURL && !editingURL && !store.isDisconnectPending {
                Section {
                    HStack {
                        RowLabel(title: "연결 해제", caption: "이 맥에 저장된 피드 주소를 지워요. 지난 기록은 남아요.")
                        Spacer()
                        if confirmingDisconnect {
                            Button("취소") { confirmingDisconnect = false }
                            Button {
                                confirmingDisconnect = false
                                sync.disconnect()
                            } label: {
                                Text("정말 해제").foregroundStyle(Palette.overdue)
                            }
                        } else {
                            Button { confirmingDisconnect = true } label: {
                                Text("연결 해제…").foregroundStyle(Palette.overdue)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)  // 창 전체를 패널과 같은 바탕색으로 (어두운 모드 = 노치 검정)
    }

    // MARK: 피드 주소

    /// 저장돼 있으면 "🔒 이 맥에만 저장됨" + 변경… (가린 주소도 화면에 보이지 않음, T-011 결정)
    @ViewBuilder
    private var feedURLRow: some View {
        if store.hasFeedURL && !editingURL {
            LabeledContent {
                HStack(spacing: 10) {
                    Text("🔒 이 맥에만 저장됨").foregroundStyle(Palette.secondaryText)
                    Button("변경…") {
                        urlInput = ""
                        urlError = nil
                        confirmingDisconnect = false
                        editingURL = true
                    }
                }
            } label: {
                RowLabel(title: "피드 주소", caption: "주소 자체가 비밀번호와 같아요")
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                RowLabel(title: "피드 주소")
                SecureField("피드 주소 (https://…/feeds/calendars/….ics)", text: $urlInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                HStack {
                    if let urlError {
                        Text(urlError)
                            .font(.caption)
                            .foregroundStyle(Palette.overdue)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("LMS 캘린더 → '캘린더 피드'에서 받은 주소를 붙여넣으세요. 주소는 이 맥에만, 본인 계정만 읽을 수 있게 저장돼요.")
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if editingURL {
                        Button("취소") {
                            urlInput = ""
                            urlError = nil
                            editingURL = false
                        }
                    }
                    Button("저장", action: save)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func save() {
        let text = urlInput
        urlInput = ""  // 성공·실패와 관계없이 입력값을 들고 있지 않는다
        if let error = sync.saveFeedURL(text) {
            urlError = error.message
        } else {
            urlError = nil
            editingURL = false
        }
    }

    // MARK: 문구

    private var lastSyncText: String {
        guard let at = store.record.lastSuccessAt else { return "없음" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 HH:mm"
        return "\(f.string(from: at)) (\(LmsDisplay.relative(at, now: store.displayNow)))"
    }

    private var statusColor: Color {
        switch store.record.status {
        case .ok, .never: return Palette.secondaryText
        case .offline, .rateLimited: return Palette.primaryText  // 확정안에 주황이 없어 본문 색 (일시적 문제)
        case .disconnected, .invalidFeed: return Palette.overdue
        }
    }
}

// MARK: - 기록 보관 (T-009 기능 그대로)

struct HistorySettingsPane: View {
    let history: HistoryService
    let onCleanup: () -> Void
    let onReset: () -> Void

    var body: some View {
        let pending = history.pending

        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    RowLabel(title: "보관 기간", caption: "이 기간보다 오래된 기록은 정리 대상이 돼요. 자동으로 지우지 않아요.")
                    Picker("보관 기간", selection: Binding(get: { history.retention }, set: { history.retention = $0 })) {
                        ForEach(HistoryRetention.allCases) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Text("정리 대상: 보관 기간보다 오래전에 완료한 내 할 일, 마감이 지난 LMS 기록과 그 체크 상태. 완료 안 한 할 일은 정리하지 않아요.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    RowLabel(title: "정리 대상 \(pending.count)개", caption: statusText(pending.count))
                    Spacer()
                    Button("지금 정리…", action: onCleanup)
                        .disabled(pending.count == 0)
                }
                HStack {
                    RowLabel(title: "모든 기록 초기화", caption: "완료한 할 일·LMS 기록·체크 상태를 지워요. 지우기 전에 자동으로 백업해요.")
                    Spacer()
                    Button(action: onReset) {
                        Text("모든 기록 초기화…").foregroundStyle(Palette.overdue)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)  // 창 전체를 패널과 같은 바탕색으로 (어두운 모드 = 노치 검정)
        .onAppear { history.recompute() }
    }

    private func statusText(_ count: Int) -> String {
        if history.retention == .never { return "기록을 정리하지 않아요." }
        if count > 0 { return "보관 기간이 지난 기록이 \(count)개 있어요." }
        return "보관 기간(\(history.retention.label))이 지난 기록이 없어요."
    }
}

// MARK: - 저장 공간 (T-009 기능 그대로)

struct StorageSettingsPane: View {
    let history: HistoryService

    /// 설정 창을 열 때·`새로 계산`을 누를 때만 계산 (타이머 없음)
    @State private var report: StorageReport?

    var body: some View {
        Form {
            if let report {
                Section {
                    ForEach(report.files) { entry in
                        row(entry.name, text(entry))
                    }
                    row(report.archive.name, text(report.archive))
                }
                Section {
                    row("합계", StorageReport.format(report.totalBytes), strong: true)
                    row("정리 대상", "\(report.cleanupCount)개")
                    row("DoIt 메모리", report.memoryBytes.map { StorageReport.format(Int64($0)) } ?? "알 수 없음")
                }
            }
            Section {
                HStack {
                    RowLabel(title: "위치", caption: "~/Library/Application Support/DoIt")
                    Spacer()
                    Button("새로 계산") { refresh() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)  // 창 전체를 패널과 같은 바탕색으로 (어두운 모드 = 노치 검정)
        .onAppear { refresh() }
        .onChange(of: history.pending) { _, _ in refresh() }
    }

    private func row(_ title: String, _ value: String, strong: Bool = false) -> some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
                .fontWeight(strong ? .semibold : .regular)
                .foregroundStyle(strong ? Palette.primaryText : Palette.secondaryText)
        } label: {
            Text(title).foregroundStyle(Palette.primaryText)
        }
    }

    private func text(_ e: StorageReport.FileEntry) -> String {
        guard let bytes = e.bytes else { return e.name == "archive/" ? "없음" : "파일 없음" }
        return "\(StorageReport.format(bytes)) · \(e.count)\(e.countUnit)"
    }

    private func refresh() {
        history.recompute()
        let lms = history.lmsStore
        report = StorageReport.make(
            directory: history.todoStore.fileURL.deletingLastPathComponent(),
            archiveDirectory: history.archiveDirectory,
            counts: .init(todos: history.todoStore.todos.count, lmsItems: lms.items.count,
                          lmsHistory: lms.history.count, lmsChecks: lms.checked.count,
                          cleanup: history.pending.count))
    }
}

// MARK: - 알림 (T-005, PRD F8)

struct AlertSettingsPane: View {
    let scheduler: NotchAlertScheduler

    @State private var testMessage: String?
    @State private var permissions: NotificationPermissionModel

    init(scheduler: NotchAlertScheduler, center: LocalNotificationCenter?) {
        self.scheduler = scheduler
        _permissions = State(initialValue: NotificationPermissionModel(center: center))
    }

    private var settings: AlertSettings { scheduler.settings }
    private var permission: AlertPermission? { permissions.permission }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { settings.todos }, set: { settings.todos = $0 })) {
                    RowLabel(title: "내 할 일 마감 알림", caption: "마감 당일 오전 9시에 노치로 알려요")
                }
                Toggle(isOn: Binding(get: { settings.lms }, set: { settings.lms = $0 })) {
                    RowLabel(title: "LMS 과제 알림 (마감 당일 오전 9시)", caption: "체크 안 한 LMS 과제를 함께 알려요")
                }
                Toggle(isOn: Binding(get: { settings.paused }, set: { settings.paused = $0 })) {
                    RowLabel(title: "노치 알림 일시 중지", caption: "수업·발표 중에 켜 두면 노치 알림을 띄우지 않아요")
                }
            }

            Section {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 4) {
                        Button("테스트 알림 보내기") { sendTest() }
                        if let testMessage {
                            Text(testMessage).font(.caption).foregroundStyle(Palette.secondaryText)
                        }
                    }
                } label: {
                    RowLabel(title: ReminderPlanner.previewText(scheduler.nextReminder),
                             caption: "하루 한 번, 그날 마감인 항목을 모아 알려요")
                }
            }

            Section {
                LabeledContent {
                    Text(permissionText).foregroundStyle(permission == .denied ? Palette.overdue : Palette.secondaryText)
                } label: {
                    RowLabel(title: "macOS 알림 권한",
                             caption: "DoIt이 종료돼 있을 때만 macOS 기본 알림으로 대신 알려요. 실행 중에는 노치 알림만 써요.")
                }
                if permission == .notDetermined {
                    HStack {
                        Text("앱이 종료된 동안의 마감 알림을 받으려면 권한을 허용해 주세요. 노치 알림에는 이 권한이 필요하지 않아요.")
                            .font(.caption).foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(permissions.isRequesting ? "요청 중…" : "알림 권한 요청") {
                            Task { await permissions.request() }
                        }
                        .disabled(permissions.isRequesting)
                    }
                }
                if let message = permissions.requestMessage {
                    Text(message).font(.caption).foregroundStyle(Palette.secondaryText)
                }
                if permission == .denied || permission == .provisional || permission == .unknown || permissions.requestMessage != nil {
                    HStack {
                        Text(permission == .denied
                             ? "앱이 종료돼 있을 때는 알림이 오지 않아요 (노치 알림은 그대로 동작해요)."
                             : "macOS 알림의 허용 여부와 표시 방식은 시스템 설정에서 확인해 주세요.")
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("시스템 설정 열기") { openSystemSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)  // 창 전체를 패널과 같은 바탕색으로
        .task { await permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions.refresh() }
        }
    }

    private var permissionText: String {
        switch permission {
        case .authorized: return "허용됨"
        case .denied: return "거부됨"
        case .notDetermined: return "아직 묻지 않음"
        case .provisional: return "조용한 알림만 허용됨"
        case .unknown: return "시스템 설정 확인 필요"
        case nil: return "확인 중…"
        }
    }

    private func sendTest() {
        switch scheduler.sendTest() {
        case .scheduled: testMessage = "3초 뒤에 노치 알림이 떠요"
        case .paused: testMessage = "일시 중지 중이라 보내지 않았어요"
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
