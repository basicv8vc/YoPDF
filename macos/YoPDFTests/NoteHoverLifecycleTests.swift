import Foundation
import XCTest
@testable import YoPDFCore

/// The hover card's lifetime is a set of timing races, so it lives in a plain
/// state machine rather than in the page overlay. These tests drive that
/// machine directly: no window, tracking area or PDF is needed to prove that a
/// delayed preview cannot fire after a scroll, a click or a pointer that left.
final class NoteHoverLifecycleTests: XCTestCase {

    // ObjectIdentifier is only an address, so keep the objects alive; two
    // short-lived temporaries could otherwise be allocated at the same address.
    private let firstObject = NSObject()
    private let secondObject = NSObject()
    private var first: ObjectIdentifier { ObjectIdentifier(firstObject) }
    private var second: ObjectIdentifier { ObjectIdentifier(secondObject) }

    // MARK: - Scrolling

    func testScrollingDuringTheDwellCancelsTheQueuedPreview() throws {
        var lifecycle = NoteHoverLifecycle()
        let token = try XCTUnwrap(scheduledToken(&lifecycle, for: first))

        XCTAssertEqual(lifecycle.pendingMarkerID, first)
        XCTAssertEqual(lifecycle.scrolled(pointerAt: nil), .cancel)
        XCTAssertNil(lifecycle.pendingMarkerID)

        // The sleeping task still wakes up, but its token is stale now.
        XCTAssertEqual(
            lifecycle.delayFinished(
                markerID: first,
                token: token,
                pointerStillOnMarker: true
            ),
            .none
        )
        XCTAssertNil(lifecycle.visibleMarkerID)
    }

    func testDelayReChecksThePointerBeforeShowing() throws {
        var lifecycle = NoteHoverLifecycle()
        let token = try XCTUnwrap(scheduledToken(&lifecycle, for: first))

        // A second line of defence: the page moved during the dwell even if no
        // bounds-changed notification reached the overlay in time.
        XCTAssertEqual(
            lifecycle.delayFinished(
                markerID: first,
                token: token,
                pointerStillOnMarker: false
            ),
            .cancel
        )
        XCTAssertNil(lifecycle.visibleMarkerID)
        XCTAssertNil(lifecycle.pendingMarkerID)
    }

    func testScrollingHidesAVisibleCardOnlyWhenThePointerLeft() {
        var lifecycle = NoteHoverLifecycle()
        show(&lifecycle, markerID: first)

        XCTAssertEqual(lifecycle.scrolled(pointerAt: first), .none)
        XCTAssertEqual(lifecycle.visibleMarkerID, first)
        XCTAssertEqual(lifecycle.scrolled(pointerAt: nil), .hide)
        XCTAssertNil(lifecycle.visibleMarkerID)
    }

    // MARK: - Dwell timing

    func testMovingInsideOneStickerDoesNotRestartTheDelay() throws {
        var lifecycle = NoteHoverLifecycle()
        let token = try XCTUnwrap(scheduledToken(&lifecycle, for: first))

        for _ in 0..<5 {
            XCTAssertEqual(
                lifecycle.pointerMoved(to: first, isPressed: false),
                .none,
                "micro-movements inside one sticker must not reset the dwell"
            )
        }

        XCTAssertEqual(
            lifecycle.delayFinished(
                markerID: first,
                token: token,
                pointerStillOnMarker: true
            ),
            .show(markerID: first)
        )
    }

    func testSwitchingStickersRestartsTheDelayAndRetiresTheOldOne() throws {
        var lifecycle = NoteHoverLifecycle()
        let oldToken = try XCTUnwrap(scheduledToken(&lifecycle, for: first))
        let newToken = try XCTUnwrap(scheduledToken(&lifecycle, for: second))

        XCTAssertNotEqual(oldToken, newToken)
        XCTAssertEqual(
            lifecycle.delayFinished(
                markerID: first,
                token: oldToken,
                pointerStillOnMarker: true
            ),
            .none
        )
        XCTAssertEqual(
            lifecycle.delayFinished(
                markerID: second,
                token: newToken,
                pointerStillOnMarker: true
            ),
            .show(markerID: second)
        )
    }

    func testAVisibleCardDoesNotRescheduleWhileThePointerStays() {
        var lifecycle = NoteHoverLifecycle()
        show(&lifecycle, markerID: first)

        XCTAssertEqual(lifecycle.pointerMoved(to: first, isPressed: false), .none)
        XCTAssertEqual(lifecycle.visibleMarkerID, first)
    }

    func testPointerLeavingAllStickersCancelsAQueuedPreview() throws {
        var lifecycle = NoteHoverLifecycle()
        let token = try XCTUnwrap(scheduledToken(&lifecycle, for: first))

        XCTAssertEqual(lifecycle.pointerMoved(to: nil, isPressed: false), .hide)
        XCTAssertEqual(
            lifecycle.delayFinished(
                markerID: first,
                token: token,
                pointerStillOnMarker: true
            ),
            .none
        )
        XCTAssertNil(lifecycle.visibleMarkerID)
    }

    func testAHardDismissalInvalidatesTheDelay() throws {
        var lifecycle = NoteHoverLifecycle()
        let token = try XCTUnwrap(scheduledToken(&lifecycle, for: first))

        XCTAssertEqual(lifecycle.hide(), .hide)
        XCTAssertEqual(
            lifecycle.delayFinished(
                markerID: first,
                token: token,
                pointerStillOnMarker: true
            ),
            .none
        )
        XCTAssertNil(lifecycle.visibleMarkerID)
    }

    // MARK: - Clicks and drags

    func testClickSuppressesTheCardUntilThePointerLeavesAllStickers() {
        var lifecycle = NoteHoverLifecycle()
        show(&lifecycle, markerID: first)

        XCTAssertEqual(lifecycle.noteActivated(markerID: first), .hide)
        XCTAssertNil(lifecycle.visibleMarkerID)
        XCTAssertEqual(lifecycle.pointerMoved(to: first, isPressed: false), .hide)
        XCTAssertNil(lifecycle.pendingMarkerID)

        // Leaving every sticker re-arms the note the user just opened.
        XCTAssertEqual(lifecycle.pointerMoved(to: nil, isPressed: false), .hide)
        XCTAssertNotNil(scheduledToken(&lifecycle, for: first))
    }

    func testFallbackClickWithoutAMarkerIDSuppressesOnlyTheOverlayWithACard() {
        var active = NoteHoverLifecycle()
        var idle = NoteHoverLifecycle()
        show(&active, markerID: first)

        // All page overlays receive the dismissal. The one with a card infers
        // its marker and suppresses it; the idle one has nothing to suppress,
        // so its own page keeps working.
        XCTAssertEqual(active.noteActivated(markerID: nil), .hide)
        XCTAssertEqual(idle.noteActivated(markerID: nil), .hide)
        if case .schedule(_, _) = active.pointerMoved(to: first, isPressed: false) {
            XCTFail("the clicked sticker must not schedule another preview")
        }

        if case .schedule(let markerID, _) = idle.pointerMoved(to: second, isPressed: false) {
            XCTAssertEqual(markerID, second)
        } else {
            XCTFail("an idle page overlay should still schedule a preview")
        }
    }

    func testAMarkerDragNeverPreviews() {
        var lifecycle = NoteHoverLifecycle()

        XCTAssertEqual(lifecycle.pointerMoved(to: first, isPressed: true), .hide)
        XCTAssertNil(lifecycle.pendingMarkerID)
        XCTAssertEqual(lifecycle.pointerMoved(to: nil, isPressed: false), .hide)
        XCTAssertNotNil(scheduledToken(&lifecycle, for: first))
    }

    // MARK: - Marker changes

    func testMarkerChangesRefreshADeletedOrEditedCard() throws {
        var lifecycle = NoteHoverLifecycle()
        show(&lifecycle, markerID: first)

        XCTAssertEqual(
            lifecycle.markersChanged(containing: [first]),
            .show(markerID: first)
        )
        XCTAssertEqual(lifecycle.markersChanged(containing: [second]), .hide)
        XCTAssertNil(lifecycle.visibleMarkerID)

        var pending = NoteHoverLifecycle()
        let token = try XCTUnwrap(scheduledToken(&pending, for: first))
        XCTAssertEqual(pending.markersChanged(containing: [second]), .none)
        XCTAssertNil(pending.pendingMarkerID)
        XCTAssertEqual(
            pending.delayFinished(
                markerID: first,
                token: token,
                pointerStillOnMarker: true
            ),
            .none
        )
    }

    // MARK: - Helpers

    private func scheduledToken(
        _ lifecycle: inout NoteHoverLifecycle,
        for markerID: ObjectIdentifier
    ) -> Int? {
        guard case .schedule(_, let token) = lifecycle.pointerMoved(
            to: markerID,
            isPressed: false
        ) else { return nil }
        return token
    }

    private func show(
        _ lifecycle: inout NoteHoverLifecycle,
        markerID: ObjectIdentifier,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let token = scheduledToken(&lifecycle, for: markerID) else {
            return XCTFail("expected a scheduled dwell", file: file, line: line)
        }
        XCTAssertEqual(
            lifecycle.delayFinished(
                markerID: markerID,
                token: token,
                pointerStillOnMarker: true
            ),
            .show(markerID: markerID),
            file: file,
            line: line
        )
    }
}
