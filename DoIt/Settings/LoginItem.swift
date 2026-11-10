import Foundation
import ServiceManagement
import os

private let loginLogger = Logger(subsystem: "com.personal.doit", category: "settings")

/// 로그인 시 자동 실행 (PRD F10, T-010). 상태는 앱이 따로 저장하지 않고 **매번 시스템(`SMAppService`)에서 읽는다**.
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// 실제 구현: 이 앱 자신(`SMAppService.mainApp`)을 로그인 항목으로 등록
struct MainAppLoginItem: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// 설정 화면에 보여 줄 내용 (순수 함수로 계산 → 테스트)
struct LoginItemDisplay: Equatable {
    /// 스위치가 켜져 보이는지
    let isOn: Bool
    /// 스위치 아래 설명
    let caption: String
    /// '로그인 항목 열기' 버튼을 보여 줄지 (사용자 승인이 필요할 때)
    let showsOpenSettings: Bool

    static let defaultCaption = "맥에 로그인하면 DoIt을 자동으로 실행해요"

    init(status: SMAppService.Status) {
        switch status {
        case .enabled:
            self.init(isOn: true, caption: Self.defaultCaption, showsOpenSettings: false)
        case .requiresApproval:
            // 등록은 됐지만 시스템 설정에서 허용해야 실제로 자동 실행된다
            self.init(isOn: true, caption: "시스템 설정 › 일반 › 로그인 항목에서 DoIt을 허용해야 자동 실행돼요",
                      showsOpenSettings: true)
        case .notFound:
            // 앱 위치를 찾지 못함 (예: /Applications가 아닌 곳에서 실행, 빌드 폴더 등)
            self.init(isOn: false, caption: "/Applications/DoIt.app에 설치한 DoIt에서 켜 주세요",
                      showsOpenSettings: false)
        default:  // .notRegistered 및 이후 추가될 값
            self.init(isOn: false, caption: Self.defaultCaption, showsOpenSettings: false)
        }
    }

    init(isOn: Bool, caption: String, showsOpenSettings: Bool) {
        self.isOn = isOn
        self.caption = caption
        self.showsOpenSettings = showsOpenSettings
    }
}

/// 스위치를 바꿨을 때: 켜기 → 등록, 끄기 → 해제. 실패하면 사용자에게 보여 줄 문장을 돌려준다
enum LoginItemAction {
    static func set(_ on: Bool, service: LoginItemService) -> String? {
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            loginLogger.info("login item \(on ? "register" : "unregister", privacy: .public) → status=\(String(describing: service.status), privacy: .public)")
            return nil
        } catch {
            loginLogger.error("login item \(on ? "register" : "unregister", privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return on ? "자동 실행을 켜지 못했어요. 시스템 설정 › 일반 › 로그인 항목을 확인해 주세요."
                      : "자동 실행을 끄지 못했어요. 시스템 설정 › 일반 › 로그인 항목에서 꺼 주세요."
        }
    }
}
