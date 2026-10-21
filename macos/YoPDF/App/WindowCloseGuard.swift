import AppKit
import SwiftUI

/// Stops a window from closing while it holds unsaved edits.
///
/// SwiftUI has no hook for "the user clicked the red button", so this sits on
/// the window's delegate. Everything the delegate does is forwarded to whoever
/// was installed before, which keeps SwiftUI's own window teardown working; only
/// `windowShouldClose` is decided here.
///
/// The guard never decides what to do about the edits. It reports the intent and
/// refuses the close; the reader presents Save / Don't Save / Cancel and then
/// either closes the window explicitly or leaves it open.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {

    enum Intent {
        /// The window's close button, ⌘W, or `performClose:`.
        case windowClose
        /// The app is quitting and this window is the first one with edits.
        case quit
    }

    private weak var window: NSWindow?
    private var isDirty: () -> Bool = { false }
    private var onUnsavedChanges: (Intent) -> Void = { _ in }
    /// Set just before the guard closes the window itself, so the close it asked
    /// for is not refused by the same check.
    private var allowsNextClose = false

    /// The delegate SwiftUI installed. Kept so its `windowWillClose` and friends
    /// still run: the guard replaces the delegate, it does not remove it.
    nonisolated(unsafe) private weak var previousDelegate: NSWindowDelegate?

    var hasUnsavedChanges: Bool { isDirty() }

    func install(
        on window: NSWindow,
        isDirty: @escaping () -> Bool,
        onUnsavedChanges: @escaping (Intent) -> Void
    ) {
        // The closures read live state, so they are refreshed on every update.
        self.isDirty = isDirty
        self.onUnsavedChanges = onUnsavedChanges

        guard self.window !== window else { return }
        self.window = window
        guard window.delegate !== self else { return }
        previousDelegate = window.delegate
        window.delegate = self
    }

    /// Asks the reader to resolve the edits, without closing anything.
    func requestResolution(for intent: Intent) {
        onUnsavedChanges(intent)
    }

    /// Closes the window, bypassing the unsaved-changes check once.
    func closeNow() {
        allowsNextClose = true
        window?.performClose(nil)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowsNextClose {
            allowsNextClose = false
            return true
        }
        if isDirty() {
            onUnsavedChanges(.windowClose)
            return false
        }
        return previousDelegate?.windowShouldClose?(sender) ?? true
    }

    // MARK: - Forwarding

    nonisolated override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return previousDelegate?.responds(to: selector) ?? false
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if let previousDelegate, previousDelegate.responds(to: selector) {
            return previousDelegate
        }
        return super.forwardingTarget(for: selector)
    }
}

/// Attaches a `WindowCloseGuard` to the window that hosts this view.
///
/// The window does not exist when the representable is created, so the install
/// happens when the view is added to a window instead of after a delay.
struct WindowCloseGuardInstaller: NSViewRepresentable {

    let guardObject: WindowCloseGuard
    let isDirty: () -> Bool
    let onUnsavedChanges: (WindowCloseGuard.Intent) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        install(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        install(from: view)
    }

    private func install(from view: NSView) {
        guard let view = view as? WindowReportingView else { return }
        view.onWindowAvailable = { window in
            guardObject.install(
                on: window,
                isDirty: isDirty,
                onUnsavedChanges: onUnsavedChanges
            )
        }
        if let window = view.window {
            view.onWindowAvailable?(window)
        }
    }
}

private final class WindowReportingView: NSView {
    var onWindowAvailable: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindowAvailable?(window)
        }
    }
}
