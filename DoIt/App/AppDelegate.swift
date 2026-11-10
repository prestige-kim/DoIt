import AppKit
import os

let appLogger = Logger(subsystem: "com.personal.doit", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: TodoStore?
    private var viewModel: NotchViewModel?
    private var windowController: NotchWindowController?
    private var statusItemController: StatusItemController?
    private var lmsSync: LmsSyncService?
    private var settingsController: SettingsWindowController?
    private var history: HistoryService?
    private var alertScheduler: NotchAlertScheduler?
    private var fallbackNotifier: FallbackNotifier?
    private var updateService: UpdateService?
    private var editorController: EditorWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 단위 테스트의 호스트로 실행될 때는 메뉴바·패널·실제 사용자 파일을 만들지 않는다 (T-002)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            appLogger.info("running as test host: skip UI setup")
            return
        }

        let updateConfiguration = UpdateConfiguration.current
        let updates = UpdateService(configuration: updateConfiguration,
                                    driver: SparkleUpdateDriver(configuration: updateConfiguration))
        self.updateService = updates
        let store = TodoStore()
        store.load()
        store.startObservingDayChanges()
        // LMS 연동 (T-007): 저장소·동기화는 TodoStore와 분리. 연동이 꺼져 있으면 네트워크 접속 없음
        let lmsStore = LmsStore()
        lmsStore.load()
        let lmsSync = LmsSyncService(store: lmsStore, feedURLStore: MigratingFeedURLStore(), fetcher: URLSessionFeedFetcher())
        let history = HistoryService(todoStore: store, lmsStore: lmsStore)
        // 노치 알림 (T-005, D-015): 실행 중에는 노치 알림, 종료 시에만 macOS 알림으로 대신 예약
        let alertSettings = AlertSettings()
        let alertScheduler = NotchAlertScheduler(settings: alertSettings, timerFactory: WallClockTimerFactory()) { [weak store, weak lmsStore] in
            .init(todos: store?.todos ?? [], lms: lmsStore?.items ?? [], checked: lmsStore?.checked ?? [:])
        }
        let notificationCenter = SystemNotificationCenter()
        let fallbackNotifier = FallbackNotifier(center: notificationCenter)
        let settingsController = SettingsWindowController(sync: lmsSync, history: history,
                                                          alerts: alertScheduler, permissionCenter: notificationCenter, updates: updates)

        let viewModel = NotchViewModel(store: store, lms: lmsStore)
        viewModel.onExpand = { [weak lmsSync] in lmsSync?.trigger(.panelExpand) }
        // 패널 머리줄 ⚙ → 메뉴 `설정…`과 같은 동작 (T-011). 설정 창을 앞으로 가져오는 활성화는 설정 창 컨트롤러 안에서만
        viewModel.onOpenSettings = { [weak settingsController] in settingsController?.show() }
        // 전체 편집기 (T-006): 메뉴·패널 머리줄 버튼으로 연다. 앱 활성화는 편집기 창 컨트롤러 안에서만
        let editorController = EditorWindowController(store: store, lms: lmsStore)
        viewModel.onOpenEditor = { [weak editorController] in editorController?.show() }
        let windowController = NotchWindowController(viewModel: viewModel)
        let statusItemController = StatusItemController(viewModel: viewModel, windowController: windowController,
                                                        lmsSync: lmsSync, settings: settingsController, history: history,
                                                        editor: editorController, updates: updates)
        history.onDataChanged = { [weak viewModel] in viewModel?.contentChanged() }
        // 날짜가 바뀌면 (자정 알림 또는 펼칠 때 확인): 지난 LMS 과제를 기록으로 옮기고, 정리 대상을 다시 계산 (T-009)
        let previousDayHandler = store.onTodayChanged
        store.onTodayChanged = { [weak store, weak lmsStore, weak history, weak editorController] in
            previousDayHandler()
            if let store { lmsStore?.archivePastItems(today: store.today) }
            history?.recompute()
            editorController?.refreshIfOpen()  // D-day·보이는 항목이 바뀜 (T-006)
        }
        history.recompute()  // 앱 실행 시

        // 노치 알림 재설정 시점: 할 일·LMS·체크·기록 정리(→ 저장소 변경)·알림 설정 변경, 날짜 변경·깨어남(스케줄러가 직접 받음)
        alertScheduler.present = { [weak viewModel] content in viewModel?.presentAlert(content) }
        alertSettings.onChange = { [weak alertScheduler] in alertScheduler?.reschedule() }
        store.onTodosChanged = { [weak alertScheduler] in alertScheduler?.reschedule() }
        let previousLmsHandler = lmsStore.onChange
        lmsStore.onChange = { [weak alertScheduler] in
            previousLmsHandler()
            alertScheduler?.reschedule()
        }
        fallbackNotifier.appLaunched()  // 대신 예약해 둔 알림 삭제, 권한 미결정이면 1번 요청
        alertScheduler.reschedule()
        alertScheduler.catchUp()        // 오늘 9:00이 지났고 아직 안 보였으면 지금
        alertScheduler.startObserving()
        self.alertScheduler = alertScheduler
        self.fallbackNotifier = fallbackNotifier
        self.editorController = editorController

        self.lmsSync = lmsSync
        self.settingsController = settingsController
        self.history = history
        self.store = store
        self.viewModel = viewModel
        self.windowController = windowController
        self.statusItemController = statusItemController

        lmsSync.startObservingWake()
        lmsSync.trigger(.launch)  // 마지막 시도 후 6시간이 안 지났으면 건너뜀

        // T-010 사용자 결정: 앱을 실행했다 = 바로 쓰겠다는 뜻 → 켠 상태로 시작하고, 메뉴 '켜기'와 같이 패널을 3초 보여 준다
        // (로그인 시 자동 실행도 같다. 이전에는 꺼진 상태로 시작해 메뉴에서 켜야 했음 — T-001)
        viewModel.turnOn()
        statusItemController.refreshIcon()
        appLogger.info("DoIt launched (state: on, peek)")
    }

    /// Finder·Spotlight·Launchpad에서 이미 실행 중인 DoIt을 다시 열었을 때 (T-010).
    /// `LSMultipleInstancesProhibited`로 두 번째 DoIt은 뜨지 않고 이 메서드가 불린다 → 패널을 한 번 펼쳤다 접는다
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        appLogger.info("reopen requested")
        viewModel?.reopened()
        return false
    }

    /// 종료 시 디바운스 대기 중인 저장이 있으면 즉시 저장한다 (T-002)
    func applicationWillTerminate(_ notification: Notification) {
        store?.flushPendingSave()
        // 앱이 종료돼 있는 동안을 대비해 macOS 기본 알림으로 대신 예약 (다음 실행 때 지움, T-005)
        if let alertScheduler, let fallbackNotifier {
            fallbackNotifier.appWillTerminate(plan: alertScheduler.currentPlan())
        }
    }
}
