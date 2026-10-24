import Combine
import XCTest
@testable import YoPDFCore

@MainActor
final class GentleUpdateReminderTests: XCTestCase {

    func testInitialStateHasNoReminder() {
        let reminder = GentleUpdateReminder()

        XCTAssertFalse(reminder.hasAvailableUpdate)
        XCTAssertNil(reminder.availableUpdateVersion)
    }

    func testFindingAnUpdatePublishesItsVersion() {
        let reminder = GentleUpdateReminder()

        reminder.didFindValidUpdate(version: "1.2.3")

        XCTAssertTrue(reminder.hasAvailableUpdate)
        XCTAssertEqual(reminder.availableUpdateVersion, "1.2.3")
    }

    func testDismissKeepsTheReminderForTheSameVersion() {
        let reminder = GentleUpdateReminder()
        reminder.didFindValidUpdate(version: "1.2.3")

        reminder.userDidMake(.dismiss, forVersion: "1.2.3")

        XCTAssertEqual(reminder.availableUpdateVersion, "1.2.3")
    }

    func testInstallClearsTheReminder() {
        let reminder = GentleUpdateReminder()
        reminder.didFindValidUpdate(version: "1.2.3")

        reminder.userDidMake(.install, forVersion: "1.2.3")

        XCTAssertFalse(reminder.hasAvailableUpdate)
    }

    func testSkipClearsTheReminderForThatVersion() {
        let reminder = GentleUpdateReminder()
        reminder.didFindValidUpdate(version: "1.2.3")

        reminder.userDidMake(.skip, forVersion: "1.2.3")

        XCTAssertNil(reminder.availableUpdateVersion)
    }

    func testConfirmedNoUpdateClearsAnOldReminder() {
        let reminder = GentleUpdateReminder()
        reminder.didFindValidUpdate(version: "1.2.3")

        reminder.didNotFindUpdate()

        XCTAssertNil(reminder.availableUpdateVersion)
    }

    func testFinishingUpdateSessionDoesNotClearDismissedReminder() {
        let reminder = GentleUpdateReminder()
        reminder.willHandleShowingUpdate(version: "1.2.3")
        reminder.userDidMake(.dismiss, forVersion: "1.2.3")

        reminder.updateSessionWillFinish()

        XCTAssertEqual(reminder.availableUpdateVersion, "1.2.3")
    }

    func testSeveralWindowsCanObserveTheSameReminderState() {
        let appReminder = GentleUpdateReminder()
        let windowA = appReminder
        let windowB = appReminder
        var versionInWindowA: String?
        var versionInWindowB: String?
        let observationA = windowA.$availableUpdateVersion.sink { version in
            MainActor.assumeIsolated {
                versionInWindowA = version
            }
        }
        let observationB = windowB.$availableUpdateVersion.sink { version in
            MainActor.assumeIsolated {
                versionInWindowB = version
            }
        }

        appReminder.didFindValidUpdate(version: "1.2.3")

        XCTAssertTrue(windowA === windowB)
        XCTAssertEqual(windowA.availableUpdateVersion, "1.2.3")
        XCTAssertEqual(windowB.availableUpdateVersion, "1.2.3")
        XCTAssertEqual(versionInWindowA, "1.2.3")
        XCTAssertEqual(versionInWindowB, "1.2.3")
        withExtendedLifetime((observationA, observationB)) {}
    }

    func testSignedFeedConfigurationRequiresHTTPSAndA32ByteKey() {
        let validKey = Data(repeating: 7, count: 32).base64EncodedString()

        XCTAssertTrue(SignedSparkleFeedConfiguration.isValid(
            feedURL: " https://updates.example.com/appcast.xml ",
            publicKey: " \(validKey) "
        ))
        XCTAssertFalse(SignedSparkleFeedConfiguration.isValid(
            feedURL: nil,
            publicKey: validKey
        ))
        XCTAssertFalse(SignedSparkleFeedConfiguration.isValid(
            feedURL: "https://updates.example.com/appcast.xml",
            publicKey: nil
        ))
        XCTAssertFalse(SignedSparkleFeedConfiguration.isValid(
            feedURL: "http://updates.example.com/appcast.xml",
            publicKey: validKey
        ))
        XCTAssertFalse(SignedSparkleFeedConfiguration.isValid(
            feedURL: "not a URL",
            publicKey: validKey
        ))
        XCTAssertFalse(SignedSparkleFeedConfiguration.isValid(
            feedURL: "https://updates.example.com/appcast.xml",
            publicKey: "not-base64"
        ))
        XCTAssertFalse(SignedSparkleFeedConfiguration.isValid(
            feedURL: "https://updates.example.com/appcast.xml",
            publicKey: Data(repeating: 1, count: 31).base64EncodedString()
        ))
    }

    func testManualCheckStillRunsOnlyWhenSparkleIsConfiguredAndReady() {
        var checksStarted = 0

        ManualUpdateCheck.runIfAvailable(isConfigured: true, canCheckForUpdates: true) {
            checksStarted += 1
        }
        ManualUpdateCheck.runIfAvailable(isConfigured: false, canCheckForUpdates: true) {
            checksStarted += 1
        }
        ManualUpdateCheck.runIfAvailable(isConfigured: true, canCheckForUpdates: false) {
            checksStarted += 1
        }

        XCTAssertEqual(checksStarted, 1)
    }

    func testScheduledUpdatePresentationIsHandledByTheReminder() {
        let reminder = GentleUpdateReminder()

        XCTAssertTrue(reminder.supportsGentleScheduledUpdateReminders)
        XCTAssertFalse(reminder.shouldHandleShowingScheduledUpdate())
    }
}
