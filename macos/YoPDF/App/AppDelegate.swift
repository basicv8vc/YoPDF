import AppKit

/// Handles the one app-level decision the reader cannot make from a view:
/// quitting with unsaved edits.
///
/// Quitting does not close windows one by one, so `windowShouldClose` never
/// runs. The delegate therefore looks for the first window that holds edits,
/// cancels the termination, and asks that window to present the same
/// Save / Don't Save / Cancel choice. When the user finishes, the reader asks to
/// terminate again and this method runs once more — with one fewer dirty window
/// each time.
///
/// The lookup goes through the guards' own registry rather than through
/// `window.delegate`: if anything replaced the delegate on a window, reading the
/// delegate slot would miss that window and quitting would drop its edits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let dirty = WindowCloseGuard.firstWithUnsavedChanges(among: sender.windows) else {
            return .terminateNow
        }
        dirty.requestResolution(for: .quit)
        return .terminateCancel
    }
}
