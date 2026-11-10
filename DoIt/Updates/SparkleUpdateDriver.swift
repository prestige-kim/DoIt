import AppKit
import Sparkle

@MainActor
final class SparkleUpdateDriver: NSObject, UpdateDriving, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private let configuration: UpdateConfiguration
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    var onChange: (() -> Void)?

    init(configuration: UpdateConfiguration) {
        self.configuration = configuration
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.onChange?() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.onChange?() }
            }
        ]
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    func start() throws {
        controller.updater.sendsSystemProfile = false
        controller.updater.automaticallyDownloadsUpdates = false
        try controller.updater.start()
    }
    func checkForUpdates() { controller.checkForUpdates(nil) }

    // Sparkle에 저장된 feed override 대신 검증한 번들 주소만 사용한다.
    func feedURLString(for updater: SPUUpdater) -> String? { configuration.feedURL?.absoluteString }
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] { [] }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard configuration.allowsDownload(updateItem.fileURL) else {
            throw NSError(domain: "DoItUpdates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "허용되지 않은 업데이트 주소예요"])
        }
    }
    func standardUserDriverWillShowModalAlert() { NSApp.activate() }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { NSApp.activate() }
    }
    func standardUserDriverShouldShowVersionHistory(for item: SUAppcastItem) -> Bool { false }
}
