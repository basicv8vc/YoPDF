import AppKit
import SwiftUI

/// Keeps the native window title in sync with the document shown by the reader.
/// Updating `NSWindow.title` leaves the standard titlebar and its double-click
/// zoom behavior under the user's macOS setting.
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
