import AppKit
import XCTest

@MainActor
final class TitlebarLayoutMetricsTests: XCTestCase {

    func testWindowedMetricsRespectTrafficLightTrailingEdgeAndMinimumBarHeight() {
        let metrics = TitlebarLayoutMetrics.compute(
            isFullScreen: false,
            systemTitlebarHeight: 28,
            zoomButtonMaxX: 66
        )
        XCTAssertEqual(metrics.leadingInset, 78)
        XCTAssertEqual(metrics.barHeight, 38)
    }

    func testTallerSystemTitlebarExpandsBarHeight() {
        let metrics = TitlebarLayoutMetrics.compute(
            isFullScreen: false,
            systemTitlebarHeight: 39.2,
            zoomButtonMaxX: 69.4
        )
        XCTAssertEqual(metrics.leadingInset, 82)
        XCTAssertEqual(metrics.barHeight, 40)
    }

    func testMissingZoomButtonUsesFallbackLeadingInset() {
        let metrics = TitlebarLayoutMetrics.compute(
            isFullScreen: false,
            systemTitlebarHeight: 0,
            zoomButtonMaxX: nil
        )
        XCTAssertEqual(metrics.leadingInset, TitlebarLayoutMetrics.fallbackLeadingInset)
        XCTAssertEqual(metrics.barHeight, TitlebarLayoutMetrics.minimumBarHeight)
    }

    func testFullScreenCollapsesLeadingInsetEvenIfZoomMaxXProvided() {
        let metrics = TitlebarLayoutMetrics.compute(
            isFullScreen: true,
            systemTitlebarHeight: 0,
            zoomButtonMaxX: 68
        )
        XCTAssertEqual(metrics.leadingInset, TitlebarLayoutMetrics.fullScreenLeadingInset)
        XCTAssertEqual(metrics.barHeight, TitlebarLayoutMetrics.minimumBarHeight)
    }

    func testDoubleClickActionMatchesMacOSGlobalDomainPreferences() {
        XCTAssertEqual(TitlebarDoubleClickAction.resolve(preference: nil), .zoom)
        XCTAssertEqual(TitlebarDoubleClickAction.resolve(preference: "Maximize"), .zoom)
        XCTAssertEqual(TitlebarDoubleClickAction.resolve(preference: "Minimize"), .miniaturize)
        XCTAssertEqual(TitlebarDoubleClickAction.resolve(preference: "None"), .none)
    }

    func testDragViewAllowsImmediateWindowDragFromInactiveWindow() {
        let view = WindowTitlebarDragNSView()
        XCTAssertTrue(view.mouseDownCanMoveWindow)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }
}
