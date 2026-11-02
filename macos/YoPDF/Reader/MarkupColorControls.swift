import AppKit
import SwiftUI
import YoPDFCore

/// The compact markup tools, grouped the way ShuaMac's reader groups them.
///
/// One rounded container holds Highlight, Underline and Strike Out with their
/// colour swatches, so the markup tools read as one editing surface instead of
/// unrelated toolbar buttons. The group is presentation only: every control
/// calls the same model method it called before.
struct MarkupToolbarGroup<Content: View>: View {

    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 2)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text markup")
    }
}

/// One icon-only tool inside `MarkupToolbarGroup`.
///
/// The label is an SF Symbol and the visible text lives in the help tag, which
/// is what keeps the group narrow enough for a single toolbar row.
struct MarkupToolButton: View {

    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(ReaderInteractiveButtonStyle())
        .accessibilityLabel(title)
        .help(help)
    }
}

/// A colour swatch with a disclosure chevron, matching ShuaMac's reader.
///
/// The swatch reports the colour the next mark will use (or the selected
/// annotation's colour). The popover keeps the custom value staged and commits
/// it with Apply; a preset applies immediately and closes, which is the
/// behaviour of the reference app.
struct MarkupColorControl: View {

    /// Spoken label, e.g. "Highlight colour".
    let title: String
    /// Popover heading, e.g. "Colour for new highlight marks".
    let paletteTitle: String
    let help: String
    let accessibilityIdentifier: String
    let color: NSColor
    let onSelect: (NSColor) -> Void

    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented = true
        } label: {
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(nsColor: color))
                    .frame(width: 12, height: 12)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                    }

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .frame(width: 25, height: 26)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        // Zero insets keep the swatch the same 28x28 target as the icon-only
        // tools, so the group's height is not stretched by the two swatches.
        .buttonStyle(ReaderInteractiveButtonStyle(insets: EdgeInsets()))
        .accessibilityLabel(title)
        .accessibilityValue(MarkupColorPalette.hex(from: color) ?? "")
        .accessibilityIdentifier(accessibilityIdentifier)
        .help(help)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            MarkupColorPopover(title: paletteTitle, color: color, onSelect: onSelect)
        }
    }
}

/// A swatch for the colour the next new mark of `kind` will use.
///
/// It observes `MarkupColorPreferences` rather than the document model: a
/// default colour is an application preference, not a document edit, so the
/// model publishes nothing when it changes. Observing the shared preferences
/// object is also what keeps two reader windows in step, and it is what
/// refreshes the swatch and the popover's checkmark immediately after a choice.
struct DefaultMarkupColorControl: View {

    @ObservedObject var preferences: MarkupColorPreferences
    let kind: MarkupKind

    var body: some View {
        MarkupColorControl(
            title: "\(kind.title) colour",
            paletteTitle: "Colour for new \(kind.title.lowercased()) marks",
            help: "Choose the colour for new \(kind.title.lowercased()) marks",
            accessibilityIdentifier: "pdf-reader-\(kind.rawValue)-color",
            color: preferences.color(for: kind)
        ) { color in
            preferences.setColor(color, for: kind)
        }
    }
}

/// Six labelled presets, a custom colour and an explicit Cancel/Apply pair.
///
/// Presets are buttons rather than a list so the six supported colours are
/// visible at once. The custom value is only offered when the user presses
/// Apply, so moving through the system colour picker cannot create one history
/// entry per intermediate colour. A fully transparent choice is refused by the
/// model, not written as an invisible annotation.
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(MarkupColorPalette.presets) { preset in
                    presetButton(preset)
                }
            }

            Divider()

            ColorPicker(
                "Custom colour",
                selection: $customColor,
                supportsOpacity: false
            )
            .accessibilityIdentifier("pdf-markup-custom-color-picker")

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    onSelect(NSColor(customColor))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 248)
    }

    private func presetButton(_ preset: MarkupColorPreset) -> some View {
        let isSelected = MarkupColorPalette.hex(from: color)?
            .caseInsensitiveCompare(preset.hex) == .orderedSame

        return Button {
            onSelect(preset.color)
            dismiss()
        } label: {
            VStack(spacing: 5) {
                Circle()
                    .fill(Color(nsColor: preset.color))
                    .frame(width: 24, height: 24)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black.opacity(0.75))
                        }
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                    }

                Text(preset.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(preset.name)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
