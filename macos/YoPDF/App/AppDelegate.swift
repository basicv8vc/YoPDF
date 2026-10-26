import AppKit
import YoPDFCore

/// Handles app events that sit above any reader view: Finder file opens and
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

    /// Finder can ask the app to open a document before SwiftUI has created a
    /// reader window. The queue keeps one request until the frontmost reader
    /// has handled it. A second request is rejected while that request is
    /// pending or waiting for the user's unsaved-work decision.
    let fileOpenRequests = FileOpenRequestQueue()

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.count == 1, let url = urls.first, url.isFileURL else {
            application.reply(toOpenOrPrint: .failure)
            return
        }
        let reply: NSApplication.DelegateReply = acceptOpenRequest(url, from: application)
            ? .success
            : .failure
        application.reply(toOpenOrPrint: reply)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        return acceptOpenRequest(url, from: sender)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // Finder can deliver several files in one callback. The reader routes
        // one request at a time, so refuse a batch instead of silently opening
        // only one of its PDFs.
        guard filenames.count == 1, let filename = filenames.first else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }

        let reply: NSApplication.DelegateReply = acceptOpenRequest(
            URL(fileURLWithPath: filename),
            from: sender
        ) ? .success : .failure
        sender.reply(toOpenOrPrint: reply)
    }

    private func acceptOpenRequest(_ url: URL, from application: NSApplication) -> Bool {
        guard fileOpenRequests.enqueue(url) else { return false }

        // A cold Finder launch already gets the WindowGroup's initial window.
        // For an app that is still running after all reader windows were closed,
        // explicitly create a new reader scene so the queued URL has a view to
        // consume it.
        if fileOpenRequests.hasHadReaderWindow,
           WindowCloseGuard.installedGuards(among: application.windows).isEmpty {
            fileOpenRequests.openReaderWindowIfAvailable()
        }
        return true
    }

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
