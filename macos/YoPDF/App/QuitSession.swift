import YoPDFCore

/// The one quit attempt shared by the app delegate and the reader windows.
///
/// Only one termination sequence can be in progress at a time, and both ends of
/// it — the delegate that asks and the window that answers — must see the same
/// approvals.
@MainActor
enum QuitSession {
    static let coordinator = QuitCoordinator<WindowCloseGuard>()
}
