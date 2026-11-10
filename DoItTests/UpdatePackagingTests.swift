import XCTest
import CoreFoundation
@testable import DoIt

final class UpdatePackagingTests: XCTestCase {
    private func values() -> [String: Any] {
        ["SUFeedURL": "https://example.github.io/DoIt/appcast.xml",
         "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
         "DoItDistributionEnabled": true, "DoItUpdateValidation": false, "SUVerifyUpdateBeforeExtraction": true,
         "SUAllowsAutomaticUpdates": false, "SUAutomaticallyUpdate": false,
         "SUEnableSystemProfiling": false]
    }
    private func packageAccepts(_ info: [String: Any]) throws -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plist = folder.appendingPathComponent("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [root.appendingPathComponent("scripts/lib/update_config.py").path, "package", plist.path]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        return task.terminationStatus == 0
    }
    func testValidReleaseCanBePackaged() throws { XCTAssertTrue(try packageAccepts(values())) }
    func testDistributionGateMissingFalseOrWrongTypeIsNotDistributable() throws {
        for flag: Any? in [nil, false, "true", 1] {
            var p = values(); p["DoItDistributionEnabled"] = flag
            XCTAssertFalse(try packageAccepts(p))
        }
    }
    func testPlaceholderIsNotDistributable() throws {
        var p = values(); p["SUFeedURL"] = "https://updates.example.invalid/appcast.xml"
        XCTAssertFalse(try packageAccepts(p))
    }
    func testLocalValidationCannotBePackaged() throws {
        var p = values(); p["DoItUpdateValidation"] = true; p["SUFeedURL"] = "http://127.0.0.1:8765/appcast.xml"
        XCTAssertFalse(try packageAccepts(p))
    }
    func testInvalidKeyAndATSExceptionsAreRejected() throws {
        var p = values(); p["SUPublicEDKey"] = "invalid"
        XCTAssertFalse(try packageAccepts(p))
        p = values(); p["NSAppTransportSecurity"] = ["NSAllowsLocalNetworking": true]
        XCTAssertFalse(try packageAccepts(p))
    }
    func testAutomaticInstallAndProfilingCannotBeEnabled() throws {
        for key in ["SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate", "SUEnableSystemProfiling"] {
            var p = values(); p[key] = true
            XCTAssertFalse(try packageAccepts(p))
        }
        var p = values(); p["SUVerifyUpdateBeforeExtraction"] = false
        XCTAssertFalse(try packageAccepts(p))
    }
    func testBuiltBundleDefaultsHaveCorrectTypesAndOneDaySchedule() {
        let p = Bundle.main.infoDictionary ?? [:]
        for (key, expected) in ["SUEnableAutomaticChecks": true, "SUAllowsAutomaticUpdates": false,
                                "SUAutomaticallyUpdate": false, "SUEnableSystemProfiling": false,
                                "SUVerifyUpdateBeforeExtraction": true] {
            XCTAssertEqual(p[key] as? Bool, expected)
            XCTAssertEqual(CFGetTypeID(p[key]! as CFTypeRef), CFBooleanGetTypeID())
        }
        XCTAssertEqual(p["SUScheduledCheckInterval"] as? Int, 86400)
        XCTAssertNil(p["NSAppTransportSecurity"])
        XCTAssertFalse(UpdateConfiguration.current.isReady, "유효 주소여도 공개 준비 gate가 꺼져 있으면 통신하지 않음")
    }
}
