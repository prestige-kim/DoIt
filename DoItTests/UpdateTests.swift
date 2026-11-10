import XCTest
@testable import DoIt

final class UpdateTests: XCTestCase {
    private let key = Data(repeating: 1, count: 32).base64EncodedString()
    private func info(_ url: String = "https://example.github.io/DoIt/appcast.xml", validation: Bool = false) -> [String: Any] {
        ["SUFeedURL": url, "SUPublicEDKey": key, "DoItUpdateValidation": validation, "DoItDistributionEnabled": true]
    }

    func testProductionRejectsUnconfiguredAndLocalFeeds() {
        for url in ["", "https://updates.example.invalid/appcast.xml", "$(FEED)",
                    " https://example.github.io/DoIt/appcast.xml", "http://example.org/appcast.xml",
                    "https://127.0.0.1/appcast.xml", "https://localhost/appcast.xml",
                    "https://name.local/appcast.xml", "https://me:@example.org/appcast.xml",
                    "https://example.org/appcast.xml?query=1", "https://example.org/appcast.xml#fragment"] {
            XCTAssertFalse(UpdateConfiguration(info: info(url)).isReady)
        }
    }

    func testPublicKeyMustBeCanonical32NonzeroBytes() {
        for invalid in ["", "$(KEY)", "not base64", Data(repeating: 0, count: 32).base64EncodedString(),
                        Data(repeating: 1, count: 31).base64EncodedString(), key + "\n"] {
            var values = info(); values["SUPublicEDKey"] = invalid
            XCTAssertFalse(UpdateConfiguration(info: values).isReady)
        }
        XCTAssertTrue(UpdateConfiguration(info: info()).isReady)
    }

    func testValidationRequiresCompileGateAndExactLoopback() {
        let values = info("http://127.0.0.1:8765/appcast.xml", validation: true)
        XCTAssertFalse(UpdateConfiguration(info: values).isReady)
        XCTAssertTrue(UpdateConfiguration(info: values, permitsLocal: true).isReady)
        for url in ["http://localhost:8765/appcast.xml", "http://192.0.2.1:8765/appcast.xml", "http://127.0.0.1:9999/appcast.xml"] {
            XCTAssertFalse(UpdateConfiguration(info: info(url, validation: true), permitsLocal: true).isReady)
        }
    }

    func testDownloadsStayInConfiguredRepositoryOrLoopback() {
        let normal = UpdateConfiguration(info: info())
        XCTAssertTrue(normal.allowsDownload(URL(string: "https://github.com/example/DoIt/releases/download/test/DoIt.zip")))
        for url in ["https://github.com/other/DoIt/releases/download/test/DoIt.zip", "https://example.org/DoIt.zip",
                    "http://127.0.0.1:8765/DoIt.zip", "https://github.com/example/DoIt/issues/test.zip"] {
            XCTAssertFalse(normal.allowsDownload(URL(string: url)))
        }
        let local = UpdateConfiguration(info: info("http://127.0.0.1:8765/appcast.xml", validation: true), permitsLocal: true)
        XCTAssertTrue(local.allowsDownload(URL(string: "http://127.0.0.1:8765/DoIt.zip")))
        XCTAssertFalse(local.allowsDownload(URL(string: "https://example.org/DoIt.zip")))
    }

    @MainActor private final class FakeDriver: UpdateDriving {
        var canCheckForUpdates = true
        var automatic = true
        var writes = 0
        var onChange: (() -> Void)?
        var starts = 0
        var checks = 0
        var failStart = false
        var automaticallyChecksForUpdates: Bool {
            get { automatic }
            set { automatic = newValue; writes += 1; onChange?() }
        }
        func start() throws {
            starts += 1
            if failStart { throw NSError(domain: "fake", code: 1) }
        }
        func checkForUpdates() { checks += 1; canCheckForUpdates = false; onChange?() }
    }

    @MainActor func testPlaceholderMakesNoStartOrCheckRequests() {
        let driver = FakeDriver()
        let service = UpdateService(configuration: UpdateConfiguration(info: info("https://updates.example.invalid/appcast.xml")), driver: driver)
        service.checkForUpdates()
        XCTAssertEqual(driver.starts, 0)
        XCTAssertEqual(driver.checks, 0)
        XCTAssertEqual(service.status, "업데이트 준비 중")
    }

    @MainActor func testDistributionGateRequiresRealBoolAndMakesNoRequests() {
        for flag: Any? in [nil, false, "true", "false", 1, 0, NSNumber(value: 1)] {
            var values = info("https://prestige-kim.github.io/DoIt/appcast.xml")
            values["DoItDistributionEnabled"] = flag
            let configuration = UpdateConfiguration(info: values)
            let driver = FakeDriver(); driver.automatic = false
            let service = UpdateService(configuration: configuration, driver: driver)
            service.checkForUpdates(); driver.onChange?(); service.checkForUpdates()
            XCTAssertFalse(configuration.isReady)
            XCTAssertFalse(configuration.allowsDownload(URL(string: "https://github.com/prestige-kim/DoIt/releases/download/v1/DoIt.zip")))
            XCTAssertEqual(service.status, "업데이트 준비 중")
            XCTAssertEqual(driver.starts, 0); XCTAssertEqual(driver.checks, 0)
            XCTAssertEqual(driver.writes, 0)
            XCTAssertFalse(service.automaticallyChecksForUpdates)
        }
    }

    @MainActor private func withExternalDistributionFlag(_ enabled: Bool, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let oldEnvironment = ProcessInfo.processInfo.environment["DoItDistributionEnabled"]
        defer {
            defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
            if let oldEnvironment { setenv("DoItDistributionEnabled", oldEnvironment, 1) }
            else { unsetenv("DoItDistributionEnabled") }
        }
        var overridden = original
        overridden["DoItDistributionEnabled"] = enabled
        defaults.setVolatileDomain(overridden, forName: UserDefaults.argumentDomain)
        setenv("DoItDistributionEnabled", enabled ? "true" : "false", 1)
        body()
    }

    @MainActor func testExternalSettingsCannotFlipDistributionGate() {
        let url = "https://prestige-kim.github.io/DoIt/appcast.xml"
        for (bundleGate, externalGate) in [(false, true), (true, false)] {
            withExternalDistributionFlag(externalGate) {
                var values = info(url)
                values["DoItDistributionEnabled"] = bundleGate
                let configuration = UpdateConfiguration(info: values)
                let driver = FakeDriver()
                let service = UpdateService(configuration: configuration, driver: driver)
                service.checkForUpdates()
                XCTAssertEqual(configuration.isReady, bundleGate)
                XCTAssertEqual(driver.starts, bundleGate ? 1 : 0)
                XCTAssertEqual(driver.checks, bundleGate ? 1 : 0)
                XCTAssertEqual(service.status, bundleGate ? "새 버전을 확인할 수 있어요" : "업데이트 준비 중")
            }
        }
    }

    func testValidationGateIsSeparateAndStrictlyTyped() {
        var values = info("http://127.0.0.1:8765/appcast.xml", validation: true)
        values["DoItDistributionEnabled"] = false
        XCTAssertTrue(UpdateConfiguration(info: values, permitsLocal: true).isReady)
        XCTAssertFalse(UpdateConfiguration(info: values).isReady)
        for flag: Any? in [nil, "true", "false", 1, 0] {
            values["DoItUpdateValidation"] = flag
            XCTAssertFalse(UpdateConfiguration(info: values, permitsLocal: true).isReady)
        }
    }

    @MainActor func testCurrentBundleGateIgnoresDefaultsArgumentsAndEnvironment() {
        let baseline = UpdateConfiguration.current
        let baselineDriver = FakeDriver()
        let baselineService = UpdateService(configuration: baseline, driver: baselineDriver)
        baselineService.checkForUpdates()
        XCTAssertFalse(baseline.isValidation)
        XCTAssertEqual(baseline.feedURL?.absoluteString, "https://prestige-kim.github.io/DoIt/appcast.xml")
        for externalGate in [true, false] {
            withExternalDistributionFlag(externalGate) {
                let current = UpdateConfiguration.current
                let driver = FakeDriver()
                let service = UpdateService(configuration: current, driver: driver)
                service.checkForUpdates()
                XCTAssertEqual(current.isReady, baseline.isReady)
                XCTAssertEqual(current.isValidation, baseline.isValidation)
                XCTAssertEqual(current.feedURL, baseline.feedURL)
                XCTAssertEqual(driver.starts, baselineDriver.starts)
                XCTAssertEqual(driver.checks, baselineDriver.checks)
                XCTAssertEqual(service.status, baselineService.status)
            }
        }
    }

    @MainActor func testSavedAutomaticChoiceIsNotResetOnLaunch() {
        let driver = FakeDriver(); driver.automatic = false
        let config = UpdateConfiguration(info: info())
        var service = UpdateService(configuration: config, driver: driver)
        XCTAssertFalse(service.automaticallyChecksForUpdates)
        XCTAssertEqual(driver.writes, 0)
        service.setAutomaticChecks(true)
        XCTAssertTrue(driver.automatic)
        service.setAutomaticChecks(false)
        service = UpdateService(configuration: config, driver: driver)
        XCTAssertFalse(service.automaticallyChecksForUpdates)
        XCTAssertEqual(driver.writes, 2)
    }

    @MainActor func testBusyStateDisablesAndDeduplicatesChecksAndNotifiesMenu() {
        let driver = FakeDriver()
        let service = UpdateService(configuration: UpdateConfiguration(info: info()), driver: driver)
        var changes = 0
        service.onChange = { changes += 1 }
        XCTAssertTrue(service.canCheckForUpdates)
        service.checkForUpdates()
        service.checkForUpdates()
        XCTAssertFalse(service.canCheckForUpdates)
        XCTAssertEqual(driver.checks, 1)
        driver.canCheckForUpdates = true; driver.onChange?()
        XCTAssertTrue(service.canCheckForUpdates)
        XCTAssertGreaterThan(changes, 0)
    }

    @MainActor func testStartFailureCannotEnableChecksLater() {
        let driver = FakeDriver(); driver.failStart = true
        let service = UpdateService(configuration: UpdateConfiguration(info: info()), driver: driver)
        driver.onChange?()
        service.checkForUpdates()
        XCTAssertFalse(service.canCheckForUpdates)
        XCTAssertEqual(driver.checks, 0)
        XCTAssertEqual(service.status, "업데이트를 시작하지 못했어요")
    }

    @MainActor func testDriverObservationDoesNotRetainService() {
        let driver = FakeDriver()
        weak var released: UpdateService?
        do {
            let service = UpdateService(configuration: UpdateConfiguration(info: info()), driver: driver)
            released = service
        }
        XCTAssertNil(released)
        driver.onChange?()
    }
}
