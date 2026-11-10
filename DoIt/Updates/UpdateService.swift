import Foundation
import Observation

@MainActor
protocol UpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var onChange: (() -> Void)? { get set }
    func start() throws
    func checkForUpdates()
}

/// 사용자 데이터 저장소를 참조하지 않는 업데이트 전용 경계.
@MainActor
@Observable
final class UpdateService {
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = true
    private(set) var status: String
    @ObservationIgnored private var started = false
    @ObservationIgnored private let driver: UpdateDriving
    @ObservationIgnored private let configuration: UpdateConfiguration
    @ObservationIgnored var onChange: (() -> Void)?

    init(configuration: UpdateConfiguration, driver: UpdateDriving) {
        self.configuration = configuration
        self.driver = driver
        status = configuration.isReady ? "새 버전을 확인할 수 있어요" : "업데이트 준비 중"
        driver.onChange = { [weak self] in self?.refresh() }
        if configuration.isReady {
            do { try driver.start(); started = true }
            catch { status = "업데이트를 시작하지 못했어요"; return }
        }
        refresh()
    }

    func refresh() {
        canCheckForUpdates = started && driver.canCheckForUpdates
        automaticallyChecksForUpdates = driver.automaticallyChecksForUpdates
        onChange?()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        // 기본값을 매번 쓰지 않는다. 사용자 조작만 Sparkle API에 전달한다.
        driver.automaticallyChecksForUpdates = enabled
        refresh()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        driver.checkForUpdates()
        refresh()
    }
}
