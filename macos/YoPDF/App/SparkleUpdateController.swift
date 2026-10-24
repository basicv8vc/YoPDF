import Combine
import Foundation
import Sparkle
import YoPDFCore

/// Owns Sparkle for the lifetime of the app and keeps the manual menu item and
/// all window titlebar reminders in sync.
@MainActor
final class SparkleUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate,
    @preconcurrency SPUStandardUserDriverDelegate {

    static let shared = SparkleUpdateController()

    @Published private(set) var canCheckForUpdates = false

    let reminder = GentleUpdateReminder()

    private let isConfigured: Bool
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: isConfigured,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    var updater: SPUUpdater {
        controller.updater
    }

    override private init() {
        isConfigured = Self.hasSignedFeedConfiguration
        super.init()

        let updater = controller.updater
        guard isConfigured else { return }

        canCheckForUpdates = updater.canCheckForUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        scheduleInitialUpdateProbe()
    }

    func checkForUpdates() {
        ManualUpdateCheck.runIfAvailable(
            isConfigured: isConfigured,
            canCheckForUpdates: canCheckForUpdates
        ) { [updater] in
            updater.checkForUpdates()
        }
    }

    /// Shows Sparkle's standard UI for an update already represented in the
    /// titlebar. Sparkle remains responsible for the session and installer.
    func showUpdate() {
        guard isConfigured else { return }
        updater.checkForUpdates()
    }

    private static var hasSignedFeedConfiguration: Bool {
        SignedSparkleFeedConfiguration.isValid(
            feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
    }

    private func scheduleInitialUpdateProbe(attempt: Int = 0) {
        guard attempt < 5 else { return }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            guard let self, self.updater.automaticallyChecksForUpdates else { return }

            if self.updater.sessionInProgress {
                self.scheduleInitialUpdateProbe(attempt: attempt + 1)
            } else {
                self.updater.checkForUpdateInformation()
            }
        }
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        reminder.didFindValidUpdate(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        reminder.didNotFindUpdate()
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate item: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        switch choice {
        case .install:
            reminder.userDidMake(.install, forVersion: item.displayVersionString)
        case .skip:
            reminder.userDidMake(.skip, forVersion: item.displayVersionString)
        case .dismiss:
            reminder.userDidMake(.dismiss, forVersion: item.displayVersionString)
        @unknown default:
            reminder.userDidMake(.other, forVersion: item.displayVersionString)
        }
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool {
        reminder.supportsGentleScheduledUpdateReminders
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        reminder.shouldHandleShowingScheduledUpdate()
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        reminder.willHandleShowingUpdate(version: update.displayVersionString)
    }

    func standardUserDriverWillFinishUpdateSession() {
        reminder.updateSessionWillFinish()
    }
}
