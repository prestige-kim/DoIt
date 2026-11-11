import AppKit
import SwiftUI
import os

private let settingsLogger = Logger(subsystem: "com.personal.doit", category: "settings")

/// 설정 창 (메뉴 "설정…", T-007). 노치 패널과 달리 **일반 창**이다.
/// 사용자가 메뉴로 직접 열 때만 앞으로 가져오기 위해 `NSApp.activate`를 쓴다 (노치 패널에서는 여전히 금지).
/// 창을 닫으면 열기 전에 쓰던 앱으로 포커스를 돌려준다.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let sync: LmsSyncService
    private let history: HistoryService
    private let alerts: NotchAlertScheduler?
    private let updates: UpdateService?
    private let permissionCenter: LocalNotificationCenter?
    /// 사이드바에서 고른 항목 (메뉴 `기록 정리 필요`로 열면 기록 보관으로)
    private let navigation = SettingsNavigation()
    private var window: NSWindow?
    /// 설정을 열기 전에 앞에 있던 앱
    private var previousApp: NSRunningApplication?

    init(sync: LmsSyncService, history: HistoryService,
         alerts: NotchAlertScheduler? = nil, permissionCenter: LocalNotificationCenter? = nil, updates: UpdateService? = nil) {
        self.sync = sync
        self.history = history
        self.alerts = alerts
        self.permissionCenter = permissionCenter
        self.updates = updates
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        sync.store.refreshDisplayNow()
        history.recompute()  // 정리 필요 여부 계산 시점: 설정 창 열 때 (T-009)

        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        NSApp.activate()  // T-007 허용: 메뉴로 연 설정 창을 앞으로 (노치 패널에서는 쓰지 않음)
        window.makeKeyAndOrderFront(nil)
        settingsLogger.info("settings window shown")
    }

    private func makeWindow() -> NSWindow {
        // DESIGN.md 설정 창: 약 720×540, 왼쪽 사이드바 (T-011)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsView.size.width, height: SettingsView.size.height),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "DoIt 설정"
        // 제목 막대도 창 바탕과 같은 색 (패널 바탕색, 어두운 모드 = 노치 검정, T-011)
        w.titlebarAppearsTransparent = true
        w.backgroundColor = NSColor(named: "PanelBackground")
        w.isReleasedWhenClosed = false
        w.delegate = self
        let hosting = NSHostingView(rootView: SettingsView(
            sync: sync, history: history, navigation: navigation,
            alerts: alerts, permissionCenter: permissionCenter, updates: updates,
            onCleanup: { [weak self] in self?.confirmCleanup() },
            onReset: { [weak self] in self?.confirmReset() }))
        hosting.sizingOptions = []  // 창 크기 고정
        w.contentView = hosting
        w.center()
        return w
    }

    // MARK: 기록 정리 확인 창 (T-009). 설정 창 위의 시트로 띄운다 (앱 활성화는 설정 창을 열 때만)

    /// 메뉴 `기록 정리 필요 (n개)`: 설정 창을 열고 확인 창을 띄운다
    func showCleanupConfirmation() {
        navigation.pane = .history
        show()
        confirmCleanup()
    }

    private func confirmCleanup() {
        guard let window else { return }
        history.recompute()
        let plan = history.pending
        guard plan.count > 0 else {
            inform(window, "정리할 기록이 없어요", "보관 기간(\(history.retention.label))이 지난 기록이 없어요.")
            return
        }
        let size = StorageReport.format(Int64(HistoryPolicy.estimatedBytes(plan, now: Date())))
        let alert = NSAlert()
        alert.messageText = "보관 기간이 지난 기록 \(plan.count)개(약 \(size))를 정리할까요?"
        alert.informativeText = "완료한 내 할 일 \(plan.todos.count)개 · LMS 기록 \(plan.lmsHistory.count)개. 완료 안 한 할 일은 지우지 않아요.\n'백업 후 정리'를 고르면 archive 폴더에 먼저 저장해요."
        alert.addButton(withTitle: "백업 후 정리")
        alert.addButton(withTitle: "그냥 정리")
        let later = alert.addButton(withTitle: "나중에")
        later.keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.perform(window) { try self.history.run(plan, backup: true) }
            case .alertSecondButtonReturn: self.perform(window) { try self.history.run(plan, backup: false) }
            default: break
            }
        }
    }

    /// 모든 기록 초기화: 두 번 확인, 항상 먼저 백업
    private func confirmReset() {
        guard let window else { return }
        let plan = history.resetPlan
        let first = NSAlert()
        first.messageText = "모든 기록을 초기화할까요?"
        first.informativeText = "완료한 내 할 일 \(plan.todos.count)개, LMS 기록 \(plan.lmsHistory.count)개, LMS 체크 상태 \(plan.lmsChecks.count)개를 지워요.\n완료 안 한 할 일·설정·피드 연결은 그대로예요. 지우기 전에 archive 폴더에 자동으로 백업해요."
        first.addButton(withTitle: "계속…")
        let cancel1 = first.addButton(withTitle: "취소")
        cancel1.keyEquivalent = "\u{1b}"
        first.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            // 첫 시트가 닫힌 뒤 다음 차례에 두 번째 확인 (시트 안에서 바로 시트를 띄우지 않음)
            DispatchQueue.main.async {
                let second = NSAlert()
                second.alertStyle = .critical
                second.messageText = "정말 초기화할까요?"
                second.informativeText = "백업 후 지워요. 되돌리려면 archive 폴더의 백업 파일이 필요해요."
                second.addButton(withTitle: "백업 후 초기화")
                let cancel2 = second.addButton(withTitle: "취소")
                cancel2.keyEquivalent = "\u{1b}"
                second.beginSheetModal(for: window) { response in
                    guard response == .alertFirstButtonReturn else { return }
                    self.perform(window) { try self.history.resetAll() }
                }
            }
        }
    }

    private func perform(_ window: NSWindow, _ action: @escaping () throws -> HistoryService.CleanupResult) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                let result = try action()
                let backup = result.backupURL.map { "백업: archive/\($0.lastPathComponent)" } ?? "백업하지 않았어요."
                self.inform(window, "기록 \(result.removedCount)개를 정리했어요", backup)
            } catch HistoryService.CleanupError.backupFailed {
                self.inform(window, "정리하지 못했어요", "백업 파일을 쓰지 못해 아무것도 지우지 않았어요.")
            } catch {
                self.inform(window, "정리를 마치지 못했어요", "일부 파일의 저장이 실패했어요. 이미 정리된 항목과 남은 항목을 다시 확인해 주세요. 만든 백업은 그대로 남아 있어요.")
            }
        }
    }

    private func inform(_ window: NSWindow, _ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "확인")
        alert.beginSheetModal(for: window)
    }

    func windowWillClose(_ notification: Notification) {
        if let app = previousApp, !app.isTerminated {
            app.activate(options: [])
            settingsLogger.info("settings closed: returned focus to previous app")
        }
        previousApp = nil
    }
}

