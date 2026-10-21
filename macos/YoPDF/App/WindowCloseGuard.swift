import AppKit
import SwiftUI
import YoPDFCore

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
///
/// Two things make that reliable rather than best-effort:
///
/// - the delegate that was there before is **owned** (see `previousDelegate`),
///   because `NSWindow.delegate` is a weak reference and taking over the slot
///   would otherwise deallocate it;
/// - every guard registers itself, so quitting does not depend on the guard
///   still being the window's delegate (see `installedGuards(among:)`).
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {

    enum Intent {
        /// The window's close button, ⌘W, or `performClose:`.
        case windowClose
        /// The app is quitting and this window is the first one with edits.
        case quit
    }

    private(set) weak var window: NSWindow?
    private var isDirty: () -> Bool = { false }
    private var revision: () -> Int = { 0 }
    private var onDiscardUnsavedChanges: () -> Void = {}
    private var onUnsavedChanges: (Intent) -> Void = { _ in }
    /// Set just before the guard closes the window itself, so the close it asked
    /// for is not refused by the same check.
    private var allowsNextClose = false

    /// The delegate that was on the window before the guard took the slot.
    ///
    /// Held **strongly** on purpose. `NSWindow.delegate` does not retain its
    /// delegate, so whatever SwiftUI put there is kept alive by the window
    /// alone; replacing it would let it die and the forwarding below would
    /// quietly stop working — taking SwiftUI's window teardown with it. The
    /// reference is dropped in `windowWillClose`, so it never outlives the
    /// window it belongs to.
    ///
    /// `nonisolated(unsafe)` only because `responds(to:)` and
    /// `forwardingTarget(for:)` are Objective-C overrides that cannot be
    /// actor-isolated; every write happens on the main actor.
    nonisolated(unsafe) private var previousDelegate: NSWindowDelegate?

    /// Re-takes the delegate slot if something replaced the guard. Removed in
    /// `windowWillClose` and in `deinit`.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    public var hasUnsavedChanges: Bool { isDirty() }
    public var editRevision: Int { revision() }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func install(
        on window: NSWindow,
        isDirty: @escaping () -> Bool,
        editRevision: @escaping () -> Int,
        discardUnsavedChanges: @escaping () -> Void,
        onUnsavedChanges: @escaping (Intent) -> Void
    ) {
        // The closures read live state, so they are refreshed on every update.
        self.isDirty = isDirty
        self.revision = editRevision
        self.onDiscardUnsavedChanges = discardUnsavedChanges
        self.onUnsavedChanges = onUnsavedChanges

        if self.window !== window {
            detachFromCurrentWindow()
            self.window = window
            Self.register(self)
            startObserving(window)
        }
        assertDelegation()
    }

    /// Asks the reader to resolve the edits, without closing anything.
    func requestResolution(for intent: Intent) {
        onUnsavedChanges(intent)
    }

    /// Closes the window, bypassing the unsaved-changes check once.
    func closeNow() {
        guard let window else { return }
        allowsNextClose = true
        window.performClose(nil)
        // `performClose:` asks `windowShouldClose:` synchronously and that call
        // consumes the flag. Clearing it afterwards means a close that never
        // asked — an unclosable window, a refused `performClose:` — cannot leave
        // a standing bypass behind.
        allowsNextClose = false
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

    func windowWillClose(_ notification: Notification) {
        // Forward first, then let go: the previous delegate is what tears the
        // scene down, and it must still be alive while it runs.
        let previous = previousDelegate
        previousDelegate = nil
        stopObserving()
        Self.unregister(self)
        window = nil
        previous?.windowWillClose?(notification)
    }

    // MARK: - Delegation

    /// Re-takes the delegate slot when something else has taken it.
    ///
    /// SwiftUI re-hosts windows (full-screen transitions, scene updates) and can
    /// install a delegate of its own without telling anyone. Losing the slot
    /// silently disables the close guard, so every view update re-checks it and
    /// chains onto whatever is there now instead of assuming the install from
    /// the first update is still in place.
    private func assertDelegation() {
        guard let window, window.delegate !== self else { return }
        previousDelegate = window.delegate
        window.delegate = self
    }

    /// Hands the window back to the delegate that was there before, if the guard
    /// still owns the slot.
    private func detachFromCurrentWindow() {
        if let window, window.delegate === self {
            window.delegate = previousDelegate
        }
        previousDelegate = nil
        stopObserving()
        Self.unregister(self)
        window = nil
    }

    private func startObserving(_ window: NSWindow) {
        let center = NotificationCenter.default
        // Becoming key or main is the moment before any close the user can
        // initiate on this window, so it is where a stolen delegate has to be
        // noticed. `queue: .main` is what makes `assumeIsolated` sound.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            let observer = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.assertDelegation()
                }
            }
            observers.append(observer)
        }
    }

    private func stopObserving() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
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

    // MARK: - Registry

    private final class WeakGuard {
        weak var value: WindowCloseGuard?
        init(_ value: WindowCloseGuard) { self.value = value }
    }

    /// Every guard currently attached to a window.
    ///
    /// Quitting has to find dirty windows even when the guard no longer owns the
    /// delegate slot; going through this list means the protection does not
    /// depend on that slot at all.
    private static var installed: [WeakGuard] = []

    private static func register(_ guardObject: WindowCloseGuard) {
        installed.removeAll { $0.value == nil }
        guard !installed.contains(where: { $0.value === guardObject }) else { return }
        installed.append(WeakGuard(guardObject))
    }

    private static func unregister(_ guardObject: WindowCloseGuard) {
        installed.removeAll { $0.value == nil || $0.value === guardObject }
    }

    /// The guards attached to any of `windows`, in registration order.
    ///
    /// Quitting has to find dirty windows even when a guard no longer owns the
    /// delegate slot, so this never reads the delegate slot.
    static func installedGuards(among windows: [NSWindow]) -> [WindowCloseGuard] {
        let candidates = Set(windows.map(ObjectIdentifier.init))
        return installed.compactMap(\.value).filter { candidate in
            guard let window = candidate.window else { return false }
            return candidates.contains(ObjectIdentifier(window))
        }
    }
}

extension WindowCloseGuard: QuitConfirmingWindow {

    public func requestQuitConfirmation() {
        onUnsavedChanges(.quit)
    }

    public func discardUnsavedChangesForQuit() {
        onDiscardUnsavedChanges()
    }
}

/// Attaches a `WindowCloseGuard` to the window that hosts this view.
///
/// The window does not exist when the representable is created, so the install
/// happens when the view is added to a window instead of after a delay.
struct WindowCloseGuardInstaller: NSViewRepresentable {

    let guardObject: WindowCloseGuard
    let isDirty: () -> Bool
    let editRevision: () -> Int
    let discardUnsavedChanges: () -> Void
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
                editRevision: editRevision,
                discardUnsavedChanges: discardUnsavedChanges,
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
