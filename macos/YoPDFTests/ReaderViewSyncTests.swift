import XCTest
@testable import YoPDFCore

/// Covers the pure decisions the `PDFView` bridge applies. The bridge itself
/// still needs a window server, so the AppKit calls are not exercised here.
final class ReaderViewSyncTests: XCTestCase {

    func testClampedPageIndexReturnsNilForEmptyDocument() {
        XCTAssertNil(ReaderViewSync.clampedPageIndex(0, pageCount: 0))
        XCTAssertNil(ReaderViewSync.clampedPageIndex(5, pageCount: 0))
    }

    func testClampedPageIndexKeepsInRangeValue() {
        XCTAssertEqual(ReaderViewSync.clampedPageIndex(0, pageCount: 3), 0)
        XCTAssertEqual(ReaderViewSync.clampedPageIndex(2, pageCount: 3), 2)
    }

    func testClampedPageIndexClampsBothEnds() {
        XCTAssertEqual(ReaderViewSync.clampedPageIndex(-4, pageCount: 3), 0)
        XCTAssertEqual(ReaderViewSync.clampedPageIndex(99, pageCount: 3), 2)
    }

    func testZoomIsAppliedWhenItDiffersBeyondTolerance() {
        XCTAssertTrue(ReaderViewSync.shouldApplyZoom(current: 1.0, target: 1.25))
        XCTAssertTrue(ReaderViewSync.shouldApplyZoom(current: 2.0, target: 0.5))
    }

    func testZoomIsNotAppliedForFloatNoise() {
        XCTAssertFalse(ReaderViewSync.shouldApplyZoom(current: 1.5, target: 1.5005))
        XCTAssertFalse(ReaderViewSync.shouldApplyZoom(current: 1.5, target: 1.5))
    }

    func testZoomRejectsNonFiniteOrNonPositiveTargets() {
        XCTAssertFalse(ReaderViewSync.shouldApplyZoom(current: .nan, target: 1.5))
        XCTAssertFalse(ReaderViewSync.shouldApplyZoom(current: 1.5, target: .nan))
        XCTAssertFalse(ReaderViewSync.shouldApplyZoom(current: 1.5, target: .infinity))
        XCTAssertFalse(ReaderViewSync.shouldApplyZoom(current: 1.5, target: 0))
        XCTAssertFalse(ReaderViewSync.shouldApplyZoom(current: 1.5, target: -1))
    }
}
