import AppKit
import YoPDFCore

/// Handles the one app-level decision the reader cannot make from a view:
/// quitting with unsaved edits.
///
/// Quitting does not close windows one by one, so `windowShouldClose` never
/// runs. The delegate therefore asks one dirty window at a time: it cancels the
/// termination and asks that window to present the same Save / Don't Save /
/// Cancel choice. When the user finishes, the reader asks to terminate again and
/// this method runs once more — with one fewer unanswered window each time.
///
/// "Don't Save" is only recorded in `QuitSession.coordinator` for this attempt;
/// the window stays open and dirty. The edits are dropped in `commit` after the
/// last window has answered, which is also the point where termination is
/// actually allowed. A Cancel clears the approvals, so a later ⌘Q asks every
/// still-dirty window again.
///
/// The lookup goes through the guards' own registry rather than through
/// `window.delegate`: if anything replaced the delegate on a window, reading the
/// delegate slot would miss that window and quitting would drop its edits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let windows = WindowCloseGuard.installedGuards(among: sender.windows)
        let coordinator = QuitSession.coordinator

        if let next = coordinator.nextWindowToAsk(among: windows) {
            next.requestQuitConfirmation()
            return .terminateCancel
        }

        // Every dirty window has answered, and none of those answers is stale.
        // Termination is committed, so this is the first moment the approved
        // edits may actually be dropped.
        coordinator.commit(among: windows)
        return .terminateNow
    }
}
