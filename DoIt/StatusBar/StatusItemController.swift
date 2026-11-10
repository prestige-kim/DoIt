import AppKit
import os

private let menuLogger = Logger(subsystem: "com.personal.doit", category: "notch-info")

/// 메뉴바 아이콘과 메뉴 (PRD F1)
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let viewModel: NotchViewModel
    private let windowController: NotchWindowController
    private let lmsSync: LmsSyncService?
    private let settings: SettingsWindowController?
    private let history: HistoryService?
    private let editor: EditorWindowController?
    private let updates: UpdateService?
    private var updateItem: NSMenuItem?
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    /// `노치 정보 출력`을 누르면 메뉴 아래쪽에 보여줄 줄들
    private var infoLines: [String] = []

    init(viewModel: NotchViewModel, windowController: NotchWindowController,
         lmsSync: LmsSyncService? = nil, settings: SettingsWindowController? = nil, history: HistoryService? = nil,
         editor: EditorWindowController? = nil, updates: UpdateService? = nil) {
        self.viewModel = viewModel
        self.windowController = windowController
        self.lmsSync = lmsSync
        self.settings = settings
        self.history = history
        self.editor = editor
        self.updates = updates
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            // D안 메뉴바 아이콘 (T-010, DESIGN.md): 단색 템플릿 → 밝은·어두운 메뉴바에 맞게 macOS가 색을 입힌다
            let image = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "checklist", accessibilityDescription: "DoIt")
            image?.isTemplate = true
            image?.accessibilityDescription = "DoIt"
            button.image = image
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu()
        updates?.onChange = { [weak self] in
            guard let self else { return }
            self.updateItem?.isEnabled = self.updates?.canCheckForUpdates == true
        }
        refreshIcon()
    }

    /// 켜짐: 아이콘 그대로 / 꺼짐: 같은 아이콘을 흐리게 (`appearsDisabled`). (T-003)
    /// 모양을 바꾸지 않아 DoIt 아이콘임을 계속 알아볼 수 있고, 흐린 표시는 macOS 메뉴바의 "비활성" 표현과 같다.
    func refreshIcon() {
        statusItem.button?.appearsDisabled = !viewModel.isOn
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // PRD F1 / T-003: 켜기·끄기는 현재 상태에 맞는 하나만
        let toggle = NSMenuItem(title: viewModel.isOn ? "DoIt 끄기" : "DoIt 켜기",
                                action: #selector(toggleOnOff), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        // T-006: 전체 편집기…(⌘E), 설정… 위
        if editor != nil {
            let editorItem = NSMenuItem(title: "전체 편집기…", action: #selector(openEditor), keyEquivalent: "e")
            editorItem.target = self
            menu.addItem(editorItem)
        }
        // T-007: 설정…(⌘,) / LMS 지금 새로고침 (연동이 켜져 있을 때만, 5분 제한·429 멈춤·진행 중이면 비활성)
        if settings != nil {
            let settingsItem = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
            settingsItem.target = self
            menu.addItem(settingsItem)
        }
        if let updates {
            let item = NSMenuItem(title: "업데이트 확인…", action: #selector(checkForUpdates), keyEquivalent: "")
            item.target = self
            item.isEnabled = updates.canCheckForUpdates
            menu.addItem(item)
            updateItem = item
            if !updates.canCheckForUpdates {
                let status = NSMenuItem(title: updates.status, action: nil, keyEquivalent: "")
                status.isEnabled = false
                menu.addItem(status)
            }
        }
        // T-009: 보관 기간이 지난 기록이 있으면 (계산은 앱 실행·날짜 변경·설정 창 열 때)
        if let history, history.pending.count > 0 {
            let cleanup = NSMenuItem(title: "기록 정리 필요 (\(history.pending.count)개)", action: #selector(openCleanup), keyEquivalent: "")
            cleanup.target = self
            menu.addItem(cleanup)
        }
        if let lmsSync, lmsSync.store.isEnabled {
            let availability = lmsSync.manualAvailability(now: Date())
            let title = availability.note.map { "LMS 지금 새로고침 (\($0))" } ?? "LMS 지금 새로고침"
            let refresh = NSMenuItem(title: title, action: #selector(refreshLms), keyEquivalent: "")
            refresh.target = self
            refresh.isEnabled = availability.enabled
            menu.addItem(refresh)
        }
        if settings != nil || lmsSync != nil || editor != nil {
            menu.addItem(.separator())
        }

        #if DEBUG
        // 디버그 항목은 Debug 빌드에서만 (T-003 결정 2-4)
        let force = NSMenuItem(title: "가상 노치 강제 (디버그)", action: #selector(toggleForceVirtual), keyEquivalent: "")
        force.target = self
        force.state = windowController.forceVirtualNotch ? .on : .off
        menu.addItem(force)

        let info = NSMenuItem(title: "노치 정보 출력 (디버그)", action: #selector(printNotchInfo), keyEquivalent: "")
        info.target = self
        menu.addItem(info)

        for line in infoLines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            menu.addItem(item)
        }

        menu.addItem(.separator())
        #endif

        let quit = NSMenuItem(title: "DoIt 종료", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleOnOff() {
        if viewModel.isOn { viewModel.turnOff() } else { viewModel.turnOn() }
        refreshIcon()
    }

    #if DEBUG
    @objc private func toggleForceVirtual() {
        windowController.forceVirtualNotch.toggle()
    }

    /// 콘솔(os.Logger)에 남기고, 메뉴를 다시 열면 아래에 텍스트로도 보인다.
    @objc private func printNotchInfo() {
        infoLines = windowController.debugInfoLines
        for line in infoLines {
            menuLogger.notice("\(line, privacy: .public)")
        }
    }
    #endif

    @objc private func checkForUpdates() { updates?.checkForUpdates() }

    @objc private func openEditor() {
        editor?.show()
    }

    @objc private func openSettings() {
        settings?.show()
    }

    @objc private func openCleanup() {
        settings?.showCleanupConfirmation()
    }

    @objc private func refreshLms() {
        lmsSync?.trigger(.manual)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
