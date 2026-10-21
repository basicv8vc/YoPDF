import AppKit
import SwiftUI
import YoPDFCore

/// A toolbar colour control: six presets plus the system colour picker.
///
/// Presets are buttons rather than a list so the six supported colours are
/// visible at once. The custom value is validated by the model; a fully
/// transparent choice is refused there instead of being written as an invisible
/// annotation.
struct MarkupColorButton: View {

    let title: String
    let help: String
    let color: NSColor
    let onSelect: (NSColor) -> Void

    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 18, height: 18)
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
                }
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            MarkupColorPopover(title: title, color: color, onSelect: onSelect)
        }
    }
}

private struct MarkupColorPopover: View {

    let title: String
    let color: NSColor
    let onSelect: (NSColor) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var customColor: Color

    init(title: String, color: NSColor, onSelect: @escaping (NSColor) -> Void) {
        self.title = title
        self.color = color
        self.onSelect = onSelect
        _customColor = State(initialValue: Color(nsColor: color))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            HStack(spacing: 8) {
                ForEach(MarkupColorPalette.presets) { preset in
                    presetButton(preset)
                }
            }

            Divider()

            ColorPicker(
                "Custom Colour",
                selection: $customColor,
                supportsOpacity: false
            )
            .onChange(of: customColor) { _, newValue in
                onSelect(NSColor(newValue))
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 238)
    }

    private func presetButton(_ preset: MarkupColorPreset) -> some View {
        let isSelected = MarkupColorPalette.hex(from: color)?
            .caseInsensitiveCompare(preset.hex) == .orderedSame

        return Button {
            onSelect(preset.color)
            dismiss()
        } label: {
            Circle()
                .fill(Color(nsColor: preset.color))
                .frame(width: 27, height: 27)
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
                }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(preset.name)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
