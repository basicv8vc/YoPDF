import AppKit
import Combine
import SwiftUI
import YoPDFCore

/// Installs one app-wide update reminder in this reader window's titlebar.
/// The zero-sized observer view does not participate in PDF layout.
struct TitlebarUpdateIndicatorInstaller: NSViewRepresentable {

    @ObservedObject var updateController: SparkleUpdateController

    func makeCoordinator() -> Coordinator {
        Coordinator(updateController: updateController)
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
        context.coordinator.attach(to: nsView.window)
        context.coordinator.refresh()
    }

    static func dismantleNSView(_ nsView: WindowObservationView, coordinator: Coordinator) {
        nsView.onWindowChange = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {

        private let updateController: SparkleUpdateController
        private weak var window: NSWindow?
        private var accessory: UpdateTitlebarAccessoryViewController?
        private var reminderObservation: AnyCancellable?

        init(updateController: SparkleUpdateController) {
            self.updateController = updateController
            reminderObservation = updateController.reminder.$availableUpdateVersion
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refresh()
                    }
                }
        }

        func attach(to newWindow: NSWindow?) {
            guard let newWindow else {
                detach()
                return
            }

            if let window, window !== newWindow {
                removeAccessory(from: window)
            }
            window = newWindow
            refresh()
        }

        func refresh() {
            refresh(version: updateController.reminder.availableUpdateVersion)
        }

        func refresh(version: String?) {
            guard let window else { return }
            guard let version else {
                removeAccessory(from: window)
                return
            }

            let accessory = accessory ?? UpdateTitlebarAccessoryViewController(
                updateController: updateController
            )
            self.accessory = accessory
            accessory.update(version: version)

            guard !window.titlebarAccessoryViewControllers.contains(where: { $0 === accessory }) else {
                return
            }
            window.addTitlebarAccessoryViewController(accessory)
        }

        func detach() {
            if let window {
                removeAccessory(from: window)
            }
            window = nil
        }

        private func removeAccessory(from window: NSWindow) {
            guard let accessory,
                  let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory })
            else {
                return
            }
            window.removeTitlebarAccessoryViewController(at: index)
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

@MainActor
private final class UpdateTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {

    private let button = NSButton()
    private let actionTarget: UpdateIndicatorActionTarget

    init(updateController: SparkleUpdateController) {
        actionTarget = UpdateIndicatorActionTarget(updateController: updateController)
        super.init(nibName: nil, bundle: nil)

        layoutAttribute = .right
        button.image = NSImage(
            systemSymbolName: "arrow.down.circle",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        )
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.bezelStyle = .toolbar
        button.isBordered = true
        button.contentTintColor = .secondaryLabelColor
        button.target = actionTarget
        button.action = #selector(UpdateIndicatorActionTarget.showUpdate(_:))
        button.setAccessibilityRole(.button)
    }

    override func loadView() {
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 32))
        button.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: accessoryView.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: accessoryView.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 26)
        ])
        view = accessoryView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(version: String) {
        let description = "YoPDF \(version) is available"
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }
}

@MainActor
private final class UpdateIndicatorActionTarget: NSObject {

    private weak var updateController: SparkleUpdateController?

    init(updateController: SparkleUpdateController) {
        self.updateController = updateController
    }

    @objc func showUpdate(_ sender: Any?) {
        updateController?.showUpdate()
    }
}
