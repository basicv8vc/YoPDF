import AppKit

/// An `NSMenuItem` that runs a closure.
///
/// Context-menu actions have to funnel through the same model entry points as
/// the toolbar. A closure keeps the menu construction next to those calls
/// instead of adding a selector for every colour and command.
@MainActor
final class MarkupActionMenuItem: NSMenuItem, NSMenuItemValidation {

    private let handler: () -> Void

    init(title: String, isEnabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: nil, keyEquivalent: "")
        target = self
        action = #selector(run)
        self.isEnabled = isEnabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// PDFKit's menu has automatic item validation. Without this, AppKit would
    /// re-enable a disabled colour/convert/delete item merely because its target
    /// responds to the action, which would contradict the permission state.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        isEnabled
    }

    @objc private func run() {
        handler()
    }
}
