import Combine
import Foundation

/// The app-wide state behind Sparkle's non-blocking update reminder.
///
/// Every reader window observes the same instance owned by
/// `SparkleUpdateController`, so the reminder stays in sync across windows.
@MainActor
public final class GentleUpdateReminder: ObservableObject {

    public enum UserChoice {
        case install
        case skip
        case dismiss
        case other
    }

    @Published public private(set) var availableUpdateVersion: String?

    public var hasAvailableUpdate: Bool {
        availableUpdateVersion != nil
    }

    public init() {}

    public func didFindValidUpdate(version: String) {
        availableUpdateVersion = version
    }

    public func didNotFindUpdate() {
        availableUpdateVersion = nil
    }

    public func userDidMake(_ choice: UserChoice, forVersion version: String) {
        switch choice {
        case .install, .skip:
            availableUpdateVersion = nil
        case .dismiss, .other:
            availableUpdateVersion = version
        }
    }

    public func willHandleShowingUpdate(version: String) {
        availableUpdateVersion = version
    }

    /// The titlebar indicator owns scheduled reminder presentation.
    public var supportsGentleScheduledUpdateReminders: Bool { true }

    public func shouldHandleShowingScheduledUpdate() -> Bool {
        false
    }

    /// Finishing a Sparkle session alone does not mean the reminder was resolved.
    public func updateSessionWillFinish() {}
}

/// Validates the signed-feed settings before Sparkle is allowed to start.
public enum SignedSparkleFeedConfiguration {

    public static func isValid(feedURL: String?, publicKey: String?) -> Bool {
        guard
            let feedURL,
            let publicKey
        else {
            return false
        }

        let feed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: feed),
            url.scheme?.lowercased() == "https",
            url.host != nil,
            let decodedKey = Data(base64Encoded: key),
            decodedKey.count == 32
        else {
            return false
        }

        return true
    }
}

/// Gates user-initiated Sparkle checks on the feed configuration and readiness.
@MainActor
public enum SparkleUpdateCheck {

    public static func runIfAvailable(
        isConfigured: Bool,
        canCheckForUpdates: Bool,
        check: () -> Void
    ) {
        guard isConfigured, canCheckForUpdates else { return }
        check()
    }
}
