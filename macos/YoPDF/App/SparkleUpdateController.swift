import Combine
import Foundation
import Sparkle

/// Owns Sparkle for the lifetime of the app and keeps the menu item in sync
/// with whether Sparkle can start a user-initiated update check.
@MainActor
final class SparkleUpdateController: ObservableObject {

    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        let isConfigured = Self.hasSignedFeedConfiguration
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        guard isConfigured else { return }

        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        guard Self.hasSignedFeedConfiguration, canCheckForUpdates else { return }
        controller.updater.checkForUpdates()
    }

    private static var hasSignedFeedConfiguration: Bool {
        guard
            let feedString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }

        let feed = feedString.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let feedURL = URL(string: feed),
            feedURL.scheme?.lowercased() == "https",
            feedURL.host != nil,
            let decodedKey = Data(base64Encoded: key),
            decodedKey.count == 32
        else {
            return false
        }

        return true
    }
}
