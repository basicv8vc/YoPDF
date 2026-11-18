import AppKit
import SwiftUI
import YoPDFCore

/// Renders the app-wide update reminder button inside the unified tab
/// titlebar row so it aligns cleanly with the `+` button and never overlaps
/// tabs.
struct TitlebarUpdateIndicatorButton: View {

    @ObservedObject var updateController: SparkleUpdateController
    @ObservedObject private var reminder: GentleUpdateReminder

    init(updateController: SparkleUpdateController) {
        self.updateController = updateController
        _reminder = ObservedObject(wrappedValue: updateController.reminder)
    }

    var body: some View {
        if let version = reminder.availableUpdateVersion {
            let description = "YoPDF \(version) is available"
            Button {
                updateController.showUpdate()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!updateController.canCheckForUpdates)
            .help(description)
            .accessibilityLabel(description)
            .accessibilityIdentifier("titlebar-update-indicator")
        }
    }
}
