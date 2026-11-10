import ServiceManagement
import XCTest
@testable import DoIt

/// 로그인 시 자동 실행 (T-010): 상태 표시와 켜기·끄기 처리. 실제 시스템 등록은 하지 않는다 (가짜 서비스)
final class LoginItemTests: XCTestCase {

    private final class FakeService: LoginItemService {
        var status: SMAppService.Status = .notRegistered
        var failNext = false
        var calls: [String] = []
        var statusAfterRegister: SMAppService.Status = .enabled
        func register() throws {
            calls.append("register")
            if failNext { throw NSError(domain: "test", code: 1) }
            status = statusAfterRegister
        }
        func unregister() throws {
            calls.append("unregister")
            if failNext { throw NSError(domain: "test", code: 2) }
            status = .notRegistered
        }
        func openSystemSettings() { calls.append("open") }
    }

    func testDisplayForEachStatus() {
        XCTAssertEqual(LoginItemDisplay(status: .notRegistered),
                       LoginItemDisplay(isOn: false, caption: LoginItemDisplay.defaultCaption, showsOpenSettings: false))
        XCTAssertEqual(LoginItemDisplay(status: .enabled),
                       LoginItemDisplay(isOn: true, caption: LoginItemDisplay.defaultCaption, showsOpenSettings: false))
        let approval = LoginItemDisplay(status: .requiresApproval)
        XCTAssertTrue(approval.isOn, "등록은 됨")
        XCTAssertTrue(approval.showsOpenSettings, "시스템 설정에서 허용하도록 버튼")
        XCTAssertTrue(approval.caption.contains("로그인 항목"))
        let notFound = LoginItemDisplay(status: .notFound)
        XCTAssertFalse(notFound.isOn)
        XCTAssertTrue(notFound.caption.contains("/Applications"))
    }

    func testTurningOnRegistersAndStatusIsReadFromService() {
        let s = FakeService()
        XCTAssertNil(LoginItemAction.set(true, service: s))
        XCTAssertEqual(s.calls, ["register"])
        XCTAssertTrue(LoginItemDisplay(status: s.status).isOn)
        XCTAssertNil(LoginItemAction.set(false, service: s))
        XCTAssertEqual(s.calls, ["register", "unregister"])
        XCTAssertFalse(LoginItemDisplay(status: s.status).isOn, "앱이 따로 저장하지 않고 시스템 상태를 따른다")
    }

    func testRegisterNeedingApprovalShowsButton() {
        let s = FakeService()
        s.statusAfterRegister = .requiresApproval
        XCTAssertNil(LoginItemAction.set(true, service: s))
        XCTAssertTrue(LoginItemDisplay(status: s.status).showsOpenSettings)
    }

    func testFailureReturnsMessageAndKeepsStatus() {
        let s = FakeService()
        s.failNext = true
        let message = LoginItemAction.set(true, service: s)
        XCTAssertNotNil(message)
        XCTAssertEqual(s.status, .notRegistered, "실패하면 스위치는 꺼진 채로 보인다")
        s.status = .enabled
        XCTAssertNotNil(LoginItemAction.set(false, service: s))
        XCTAssertEqual(s.status, .enabled)
    }
}
