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
        XCTAssertEqual(TitlebarDoubleClickAction.resolve(preference: "Fill"), .fill)
        XCTAssertEqual(TitlebarDoubleClickAction.resolve(preference: "Maximize"), .zoom)
        XCTAssertEqual(TitlebarDoubleClickAction.resolve(preference: "Minimize"), .miniaturize)
        XCTAssertEqual(TitlebarDoubleClickAction.resolve(preference: "None"), .none)
    }

    func testDragViewAllowsImmediateWindowDragFromInactiveWindow() {
        let view = WindowTitlebarDragNSView()
        XCTAssertTrue(view.mouseDownCanMoveWindow)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testDoubleClickDispatchesResolvedActionAndSupportsFill() throws {
        let window = makeTestTitlebarWindow()
        defer { window.close() }

        let dragView = try XCTUnwrap(window.contentView?.subviews.first as? WindowTitlebarDragNSView)
        var recordedActions: [TitlebarDoubleClickAction] = []
        var preference: String? = "Fill"
        dragView.doubleClickPreferenceProvider = { preference }
        dragView.doubleClickExecutor = { action, targetWindow in
            recordedActions.append(action)
            if action == .fill || action == .none {
                WindowTitlebarDragNSView.performStandardDoubleClickAction(action, on: targetWindow)
            }
        }

        let titlebarMinY = window.contentLayoutRect.maxY
        let lowerPoint = NSPoint(x: 220, y: max(1, titlebarMinY - 5))
        let initialFrame = window.frame
        try sendDoubleClick(at: lowerPoint, to: dragView, in: window)

        XCTAssertEqual(recordedActions, [.fill])
        let expectedFillFrame = (window.screen ?? NSScreen.main)?.visibleFrame
        if let expectedFillFrame {
            XCTAssertEqual(window.frame, expectedFillFrame)
            XCTAssertGreaterThan(window.frame.width, initialFrame.width)

            // Repeating a Fill double-click keeps the window filled instead of toggling back.
            try sendDoubleClick(at: lowerPoint, to: dragView, in: window)
            XCTAssertEqual(recordedActions, [.fill, .fill])
            XCTAssertEqual(window.frame, expectedFillFrame)
        }

        // Single-click mouseUp must not trigger any double-click action.
        let singleUp = try makeMouseEvent(type: .leftMouseUp, location: lowerPoint, clickCount: 1, in: window)
        dragView.mouseUp(with: singleUp)
        XCTAssertEqual(recordedActions.count, 2)

        // Stray double-click mouseUp without a preceding double-click mouseDown is ignored.
        let strayUp = try makeMouseEvent(type: .leftMouseUp, location: lowerPoint, clickCount: 2, in: window)
        dragView.mouseUp(with: strayUp)
        XCTAssertEqual(recordedActions.count, 2)

        for (pref, expected) in [
            ("Maximize", TitlebarDoubleClickAction.zoom),
            ("Minimize", TitlebarDoubleClickAction.miniaturize),
            ("None", TitlebarDoubleClickAction.none),
        ] {
            preference = pref
            try sendDoubleClick(at: lowerPoint, to: dragView, in: window)
            XCTAssertEqual(recordedActions.last, expected)
        }
    }

    private func makeTestTitlebarWindow() -> NSWindow {
        let initialOrigin = NSScreen.main?.visibleFrame.origin ?? NSPoint(x: 120, y: 120)
        let window = NSWindow(
            contentRect: NSRect(x: initialOrigin.x + 120, y: initialOrigin.y + 120, width: 420, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        let dragView = WindowTitlebarDragNSView(frame: NSRect(x: 0, y: 262, width: 420, height: 38))
        dragView.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(dragView)
        window.contentView = contentView
        return window
    }

    private func sendDoubleClick(at location: NSPoint, to view: WindowTitlebarDragNSView, in window: NSWindow) throws {
        let down = try makeMouseEvent(type: .leftMouseDown, location: location, clickCount: 2, in: window)
        let up = try makeMouseEvent(type: .leftMouseUp, location: location, clickCount: 2, in: window)
        view.mouseDown(with: down)
        view.mouseUp(with: up)
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        clickCount: Int,
        in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: clickCount,
                pressure: type == .leftMouseDown ? 1.0 : 0.0
            )
        )
    }
}
