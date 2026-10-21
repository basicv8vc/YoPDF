import XCTest
@testable import YoPDFCore

/// The multi-window quit sequence, without AppKit or a window server.
///
/// `Harness` mirrors the loop in `AppDelegate.applicationShouldTerminate`; the
/// only production logic it drives is `QuitCoordinator`.
@MainActor
final class QuitCoordinatorTests: XCTestCase {

    /// Stands in for `WindowCloseGuard` and the document model behind it.
    @MainActor
    private final class FakeWindow: QuitConfirmingWindow {
        var hasUnsavedChanges: Bool
        var editRevision: Int
        private(set) var quitConfirmationRequests = 0
        private(set) var discardedRevisions: [Int] = []

        init(dirty: Bool, revision: Int) {
            self.hasUnsavedChanges = dirty
            self.editRevision = revision
        }

        func requestQuitConfirmation() {
            quitConfirmationRequests += 1
        }

        func discardUnsavedChangesForQuit() {
            discardedRevisions.append(editRevision)
            hasUnsavedChanges = false
            editRevision += 1
        }

        /// A new edit while the window is still on screen.
        func edit() {
            hasUnsavedChanges = true
            editRevision += 1
        }

        /// A successful manual save.
        func save() {
            hasUnsavedChanges = false
            editRevision += 1
        }
    }

    @MainActor
    private final class Harness {
        let a: FakeWindow
        let b: FakeWindow
        let coordinator: QuitCoordinator<FakeWindow>

        init(a: FakeWindow, b: FakeWindow) {
            self.a = a
            self.b = b
            self.coordinator = QuitCoordinator<FakeWindow>()
        }

        var windows: [FakeWindow] { [a, b] }

        /// Returns whether termination was allowed.
        @discardableResult
        func applicationShouldTerminate() -> Bool {
            if let next = coordinator.nextWindowToAsk(among: windows) {
                next.requestQuitConfirmation()
                return false
            }
            coordinator.commit(among: windows)
            return true
        }

        /// "Don't Save", followed by the termination retry the reader triggers.
        @discardableResult
        func chooseDontSave(_ window: FakeWindow) -> Bool {
            coordinator.approveDiscard(of: window)
            return applicationShouldTerminate()
        }

        /// "Save": the document is clean before termination is retried.
        @discardableResult
        func chooseSave(_ window: FakeWindow) -> Bool {
            window.save()
            return applicationShouldTerminate()
        }

        /// The alert's Cancel button.
        func chooseCancel() {
            coordinator.cancel()
        }
    }

    private func makeHarness() -> Harness {
        Harness(
            a: FakeWindow(dirty: true, revision: 1),
            b: FakeWindow(dirty: true, revision: 2)
        )
    }

    /// A Don't Save → B Cancel: both windows stay open, A is still dirty, and
    /// nothing was discarded.
    func testDontSaveThenCancelKeepsTheFirstWindowDirty() {
        let harness = makeHarness()

        XCTAssertFalse(harness.applicationShouldTerminate(), "A is asked first")
        XCTAssertEqual(harness.a.quitConfirmationRequests, 1)

        XCTAssertFalse(
            harness.chooseDontSave(harness.a),
            "B still has to answer, so termination is not allowed yet"
        )
        XCTAssertEqual(harness.b.quitConfirmationRequests, 1)
        XCTAssertTrue(
            harness.a.hasUnsavedChanges,
            "A's edits stay on screen and dirty until the quit is confirmed"
        )
        XCTAssertTrue(harness.a.discardedRevisions.isEmpty)

        harness.chooseCancel()

        XCTAssertTrue(harness.a.hasUnsavedChanges)
        XCTAssertTrue(harness.b.hasUnsavedChanges)
        XCTAssertTrue(harness.a.discardedRevisions.isEmpty)
        XCTAssertTrue(harness.b.discardedRevisions.isEmpty)
    }

    /// A Save → B Cancel: A is clean because it was actually saved, B is still
    /// dirty, and no discard was reported for either window.
    func testSaveThenCancelLeavesTheSavedWindowClean() {
        let harness = makeHarness()

        XCTAssertFalse(harness.applicationShouldTerminate())
        XCTAssertFalse(
            harness.chooseSave(harness.a),
            "B is still dirty and must be asked"
        )
        XCTAssertFalse(harness.a.hasUnsavedChanges)

        harness.chooseCancel()

        XCTAssertFalse(harness.a.hasUnsavedChanges)
        XCTAssertTrue(harness.b.hasUnsavedChanges)
        XCTAssertTrue(harness.a.discardedRevisions.isEmpty)
    }

    /// A Don't Save → B Don't Save: termination is allowed, and only then are
    /// both sets of edits discarded.
    func testDontSaveForEveryWindowTerminatesAndDiscardsBoth() {
        let harness = makeHarness()

        XCTAssertFalse(harness.applicationShouldTerminate())
        XCTAssertFalse(harness.chooseDontSave(harness.a))
        XCTAssertTrue(
            harness.a.hasUnsavedChanges,
            "A is still on screen while B is being asked"
        )

        XCTAssertTrue(harness.chooseDontSave(harness.b), "the last answer allows termination")

        XCTAssertFalse(harness.a.hasUnsavedChanges)
        XCTAssertFalse(harness.b.hasUnsavedChanges)
        XCTAssertEqual(harness.a.discardedRevisions, [1])
        XCTAssertEqual(harness.b.discardedRevisions, [2])
    }

    /// A Cancel: the sequence stops immediately, before B is asked.
    func testCancelStopsTheAttemptWithoutDiscardingAnything() {
        let harness = makeHarness()

        XCTAssertFalse(harness.applicationShouldTerminate())
        harness.chooseCancel()

        XCTAssertTrue(harness.a.hasUnsavedChanges)
        XCTAssertTrue(harness.a.discardedRevisions.isEmpty)
        XCTAssertTrue(harness.b.discardedRevisions.isEmpty)
        XCTAssertEqual(harness.b.quitConfirmationRequests, 0, "cancel stops before B is asked")
    }

    /// After a cancel, a new ⌘Q asks every still-dirty window again; the
    /// approval from the cancelled attempt is not reused.
    func testANewQuitAttemptAsksTheDirtyWindowsAgain() {
        let harness = makeHarness()

        XCTAssertFalse(harness.applicationShouldTerminate())
        XCTAssertFalse(harness.chooseDontSave(harness.a))
        harness.chooseCancel()

        XCTAssertFalse(harness.applicationShouldTerminate())
        XCTAssertEqual(harness.a.quitConfirmationRequests, 2)
        XCTAssertEqual(harness.b.quitConfirmationRequests, 1, "B is asked after A answers")

        XCTAssertFalse(harness.chooseDontSave(harness.a))
        XCTAssertEqual(harness.b.quitConfirmationRequests, 2)
        XCTAssertTrue(harness.a.hasUnsavedChanges)
    }

    /// A "Don't Save" only covers the revision it was given for. A later edit
    /// makes the window ask again instead of being discarded silently.
    func testAnEditAfterDontSaveInvalidatesTheApproval() {
        let harness = makeHarness()

        XCTAssertFalse(harness.applicationShouldTerminate())
        XCTAssertFalse(harness.chooseDontSave(harness.a))
        XCTAssertEqual(harness.b.quitConfirmationRequests, 1)

        harness.a.edit()

        // B answers Don't Save and termination is retried.
        harness.coordinator.approveDiscard(of: harness.b)
        XCTAssertFalse(harness.applicationShouldTerminate())
        XCTAssertEqual(harness.a.quitConfirmationRequests, 2)
        XCTAssertTrue(harness.a.hasUnsavedChanges)
        XCTAssertTrue(harness.a.discardedRevisions.isEmpty)
    }

    /// A window that was saved after its "Don't Save" is clean and must not be
    /// reported as discarded when termination commits.
    func testCommitIgnoresAWindowThatWasSavedAfterApproval() {
        let harness = makeHarness()

        XCTAssertFalse(harness.applicationShouldTerminate())
        XCTAssertFalse(harness.chooseDontSave(harness.a))
        harness.a.save()

        XCTAssertTrue(harness.chooseDontSave(harness.b))
        XCTAssertFalse(harness.a.hasUnsavedChanges)
        XCTAssertTrue(harness.a.discardedRevisions.isEmpty)
        XCTAssertEqual(harness.b.discardedRevisions, [2])
    }
}
