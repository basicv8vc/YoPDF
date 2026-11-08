import CoreGraphics
import XCTest
@testable import YoPDFCore

/// Placement of the note hover card.
///
/// The card lives inside a page overlay, which clips: a placement that leaves
/// the page rectangle is a card the reader never sees. Every case here is
/// therefore about staying inside the page and staying off the sticker.
final class NoteHoverCardLayoutTests: XCTestCase {

    private let container = CGRect(x: 40, y: 60, width: 500, height: 700)
    private let card = CGSize(width: 260, height: 180)

    func testSitsAboveTheStickerWhenThePageHasRoom() {
        let sticker = CGRect(x: 200, y: 300, width: 38, height: 32)

        let frame = NoteHoverCardLayout.frame(
            cardSize: card,
            stickerFrame: sticker,
            container: container
        )

        XCTAssertEqual(frame.size, card, "the card keeps the size it was measured at")
        XCTAssertEqual(frame.minY, sticker.maxY + NoteHoverCardLayout.gap, accuracy: 0.001)
        XCTAssertEqual(frame.midX, sticker.midX, accuracy: 0.001, "it is centred on the sticker")
        XCTAssertGreaterThan(frame.minY, sticker.maxY, "above means it does not cover the sticker")
    }

    func testFlipsBelowWhenThePageEdgeIsInTheWay() {
        // Near the top of the page there is no room for a 180pt card.
        let sticker = CGRect(x: 200, y: 660, width: 38, height: 32)

        let frame = NoteHoverCardLayout.frame(
            cardSize: card,
            stickerFrame: sticker,
            container: container
        )

        XCTAssertEqual(frame.maxY, sticker.minY - NoteHoverCardLayout.gap, accuracy: 0.001)
        XCTAssertLessThan(frame.maxY, sticker.minY, "below means it does not cover the sticker either")
    }

    func testStaysInsideThePageAtTheLeftAndRightEdges() {
        let leftSticker = CGRect(x: 44, y: 300, width: 38, height: 32)
        let rightSticker = CGRect(x: 500, y: 300, width: 38, height: 32)

        let left = NoteHoverCardLayout.frame(
            cardSize: card,
            stickerFrame: leftSticker,
            container: container
        )
        let right = NoteHoverCardLayout.frame(
            cardSize: card,
            stickerFrame: rightSticker,
            container: container
        )

        XCTAssertEqual(left.minX, container.minX + NoteHoverCardLayout.inset, accuracy: 0.001)
        XCTAssertEqual(right.maxX, container.maxX - NoteHoverCardLayout.inset, accuracy: 0.001)
    }

    func testFallsBackToTheClosestLegalPositionWhenNeitherSideFits() {
        let shortPage = CGRect(x: 0, y: 0, width: 400, height: 200)
        let sticker = CGRect(x: 180, y: 84, width: 38, height: 32)

        let frame = NoteHoverCardLayout.frame(
            cardSize: card,
            stickerFrame: sticker,
            container: shortPage
        )

        let usable = shortPage.insetBy(
            dx: NoteHoverCardLayout.inset,
            dy: NoteHoverCardLayout.inset
        )
        XCTAssertEqual(frame.minY, usable.maxY - frame.height, accuracy: 0.001)
        XCTAssertNotEqual(frame.size, .zero, "a card that overlaps the sticker still beats no card")
    }

    func testClampsAnOversizedCardToThePage() {
        let sticker = CGRect(x: 200, y: 300, width: 38, height: 32)

        let frame = NoteHoverCardLayout.frame(
            cardSize: CGSize(width: 900, height: 900),
            stickerFrame: sticker,
            container: container
        )

        let usable = container.insetBy(
            dx: NoteHoverCardLayout.inset,
            dy: NoteHoverCardLayout.inset
        )
        XCTAssertEqual(frame.size, usable.size)
        XCTAssertTrue(usable.contains(frame))
    }

    func testNeverLeavesThePageForAnyStickerPosition() {
        for x in stride(from: CGFloat(20), through: 560, by: 40) {
            for y in stride(from: CGFloat(20), through: 780, by: 40) {
                let sticker = CGRect(x: x, y: y, width: 38, height: 32)
                let frame = NoteHoverCardLayout.frame(
                    cardSize: card,
                    stickerFrame: sticker,
                    container: container
                )
                let usable = container.insetBy(
                    dx: NoteHoverCardLayout.inset,
                    dy: NoteHoverCardLayout.inset
                )
                XCTAssertTrue(
                    usable.contains(frame),
                    "a card at sticker (\(x), \(y)) escaped the page: \(frame)"
                )
            }
        }
    }

    func testReturnsNothingWithoutRoom() {
        let sticker = CGRect(x: 10, y: 10, width: 38, height: 32)

        XCTAssertEqual(
            NoteHoverCardLayout.frame(
                cardSize: card,
                stickerFrame: sticker,
                container: CGRect(x: 0, y: 0, width: 12, height: 12)
            ),
            .zero
        )
        XCTAssertEqual(
            NoteHoverCardLayout.frame(
                cardSize: CGSize(width: CGFloat.nan, height: 10),
                stickerFrame: sticker,
                container: container
            ),
            .zero
        )
    }

    // MARK: - Thread fitting

    func testFitsWholeEntriesIncludingSeparators() {
        let heights: [CGFloat] = [40, 40, 40]

        XCTAssertEqual(
            NoteHoverCardLayout.visibleEntryCount(
                entryHeights: heights,
                separatorHeight: 8,
                availableHeight: 96
            ),
            2,
            "40 + 8 + 40 fits; the third entry would need 136"
        )
        XCTAssertEqual(
            NoteHoverCardLayout.visibleEntryCount(
                entryHeights: heights,
                separatorHeight: 8,
                availableHeight: 136
            ),
            3
        )
    }

    func testReportsWhatDoesNotFit() {
        XCTAssertEqual(
            NoteHoverCardLayout.visibleEntryCount(
                entryHeights: [40, 40],
                separatorHeight: 8,
                availableHeight: 39
            ),
            0
        )
        XCTAssertEqual(
            NoteHoverCardLayout.visibleEntryCount(
                entryHeights: [40, 40],
                separatorHeight: 8,
                availableHeight: 0
            ),
            0
        )
        XCTAssertEqual(
            NoteHoverCardLayout.visibleEntryCount(
                entryHeights: [],
                separatorHeight: 8,
                availableHeight: 100
            ),
            0
        )
    }

    func testCountsZeroHeightEntriesWithoutConsumingRoom() {
        XCTAssertEqual(
            NoteHoverCardLayout.visibleEntryCount(
                entryHeights: [0, 40],
                separatorHeight: 8,
                availableHeight: 40
            ),
            1,
            "the empty entry counts as a row but the 40pt body after it does not fit"
        )
    }
}
