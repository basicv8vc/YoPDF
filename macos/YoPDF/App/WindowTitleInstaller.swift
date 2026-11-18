import AppKit
import SwiftUI

struct TitlebarLayoutMetrics: Equatable {
    var leadingInset: CGFloat = 78
    var barHeight: CGFloat = 38

    static let minimumBarHeight: CGFloat = 38
    static let fullScreenLeadingInset: CGFloat = 10
    static let fallbackLeadingInset: CGFloat = 78
    static let trafficLightSpacing: CGFloat = 12

    static func compute(
        isFullScreen: Bool,
        systemTitlebarHeight: CGFloat,
        zoomButtonMaxX: CGFloat?
    ) -> TitlebarLayoutMetrics {
        let barHeight = max(minimumBarHeight, ceil(max(0, systemTitlebarHeight)))
        let leadingInset: CGFloat
        if isFullScreen {
            leadingInset = fullScreenLeadingInset
        } else if let zoomButtonMaxX {
            leadingInset = max(fullScreenLeadingInset, ceil(zoomButtonMaxX) + trafficLightSpacing)
        } else {
            leadingInset = fallbackLeadingInset
        }
        return TitlebarLayoutMetrics(leadingInset: leadingInset, barHeight: barHeight)
    }
}

enum TitlebarDoubleClickAction: Equatable {
    case fill
    case zoom
    case miniaturize
    case none

    static func resolve(preference: String?) -> TitlebarDoubleClickAction {
        switch preference {
        case "Fill":
            return .fill
        case "Minimize":
            return .miniaturize
        case "None":
            return .none
        default:
            return .zoom
        }
    }
}

@MainActor
final class WindowObservationView: NSView {

    var onWindowChange: ((NSWindow?) -> Void)?

    override var intrinsicContentSize: NSSize { .zero }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

/// Keeps the native window title in sync with the document shown by the reader.
/// Updating `NSWindow.title` preserves Window menu entries, Mission Control
/// labels, and accessibility titles even when the visual titlebar text is hidden.
struct WindowTitleInstaller: NSViewRepresentable {

    let title: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowObservationView {
        let view = WindowObservationView()
        view.isHidden = true
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowObservationView, context: Context) {
        context.coordinator.update(title: title)
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: WindowObservationView, coordinator: Coordinator) {
        nsView.onWindowChange = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {

        private weak var window: NSWindow?
        private var title = "YoPDF"

        func update(title: String) {
            self.title = title
            applyTitle()
        }

        func attach(to newWindow: NSWindow?) {
            guard let newWindow else {
                detach()
                return
            }
            window = newWindow
            applyTitle()
        }

        func detach() {
            window = nil
        }

        private func applyTitle() {
            guard let window, window.title != title else { return }
            window.title = title
        }
    }
}

/// Observes the hosting window's traffic-light geometry and fullscreen state so
/// the unified top tab strip clears the window buttons cleanly across macOS
/// releases without leaving an oversized gap in fullscreen.
struct TitlebarMetricsObserver: NSViewRepresentable {

    @Binding var metrics: TitlebarLayoutMetrics

    func makeCoordinator() -> Coordinator {
        Coordinator(metrics: $metrics)
    }

    func makeNSView(context: Context) -> WindowObservationView {
        let view = WindowObservationView()
        view.isHidden = true
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowObservationView, context: Context) {
        context.coordinator.metricsBinding = $metrics
        context.coordinator.attach(to: nsView.window)
        context.coordinator.scheduleRefresh()
    }

    static func dismantleNSView(_ nsView: WindowObservationView, coordinator: Coordinator) {
        nsView.onWindowChange = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {

        var metricsBinding: Binding<TitlebarLayoutMetrics>
        private weak var window: NSWindow?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        private var refreshScheduled = false

        init(metrics: Binding<TitlebarLayoutMetrics>) {
            self.metricsBinding = metrics
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func attach(to newWindow: NSWindow?) {
            guard window !== newWindow else { return }
            removeObservers()
            window = newWindow
            guard let newWindow else { return }

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didChangeScreenNotification
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: newWindow,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshNow()
                    }
                }
            }
            scheduleRefresh()
        }

        func detach() {
            removeObservers()
            window = nil
        }

        func scheduleRefresh() {
            guard !refreshScheduled else { return }
            refreshScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.refreshNow()
            }
        }

        func refreshNow() {
            guard let window else { return }
            let next = Self.computeMetrics(for: window)
            if metricsBinding.wrappedValue != next {
                metricsBinding.wrappedValue = next
            }
        }

        private func removeObservers() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
        }

        private static func computeMetrics(for window: NSWindow) -> TitlebarLayoutMetrics {
            let isFullScreen = window.styleMask.contains(.fullScreen)
            let systemTitlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)

            let zoomButtonMaxX: CGFloat?
            if !isFullScreen,
               let zoomButton = window.standardWindowButton(.zoomButton),
               !zoomButton.isHidden,
               zoomButton.window === window {
                zoomButtonMaxX = zoomButton.convert(zoomButton.bounds, to: nil).maxX
            } else {
                zoomButtonMaxX = nil
            }

            return TitlebarLayoutMetrics.compute(
                isFullScreen: isFullScreen,
                systemTitlebarHeight: systemTitlebarHeight,
                zoomButtonMaxX: zoomButtonMaxX
            )
        }
    }
}

/// Interactive drag/double-click region for empty space in the unified tab
/// titlebar row, restoring standard window move and titlebar zoom/minimize.
struct WindowTitlebarDragArea: NSViewRepresentable {

    func makeNSView(context: Context) -> WindowTitlebarDragNSView {
        WindowTitlebarDragNSView()
    }

    func updateNSView(_ nsView: WindowTitlebarDragNSView, context: Context) {}
}

@MainActor
final class WindowTitlebarDragNSView: NSView {

    var doubleClickPreferenceProvider: () -> String? = {
        UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
    }
    var doubleClickExecutor: (TitlebarDoubleClickAction, NSWindow) -> Void = { action, window in
        performStandardDoubleClickAction(action, on: window)
    }

    private var pendingDoubleClick = false

    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2 {
            pendingDoubleClick = true
            return
        }
        pendingDoubleClick = false
        window.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if pendingDoubleClick {
            pendingDoubleClick = false
            guard let window, event.clickCount == 2 else { return }
            let action = TitlebarDoubleClickAction.resolve(preference: doubleClickPreferenceProvider())
            doubleClickExecutor(action, window)
            return
        }
        super.mouseUp(with: event)
    }

    /// Executes the resolved macOS titlebar double-click action on `window`.
    /// `.zoom` and `.miniaturize` delegate directly to AppKit's standard window
    /// actions, while `.fill` expands the window to the active screen's
    /// `visibleFrame` because `.fullSizeContentView` + transparent titlebars
    /// suppress AppKit's private titlebar double-click dispatcher and AppKit
    /// exposes no public `performFill:` selector.
    static func performStandardDoubleClickAction(_ action: TitlebarDoubleClickAction, on window: NSWindow) {
        switch action {
        case .fill:
            guard !window.styleMask.contains(.fullScreen),
                  let screen = window.screen ?? NSScreen.main
            else { return }
            let targetFrame = screen.visibleFrame
            guard window.frame != targetFrame else { return }
            window.setFrame(targetFrame, display: true, animate: true)
        case .zoom:
            window.performZoom(nil)
        case .miniaturize:
            window.performMiniaturize(nil)
        case .none:
            break
        }
    }
}
