import AppKit
import SwiftUI

/// Adds a consistent hover and press response to the reader's custom buttons.
/// System-styled buttons can keep their native appearance; this style is for
/// controls that opt out of SwiftUI's built-in button chrome.
struct ReaderInteractiveButtonStyle: ButtonStyle {
    var isSelected = false
    var isProminent = false
    var insets = EdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)

    func makeBody(configuration: Configuration) -> some View {
        ReaderInteractiveButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            isSelected: isSelected,
            isProminent: isProminent,
            insets: insets
        )
    }
}

private struct ReaderInteractiveButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let isSelected: Bool
    let isProminent: Bool
    let insets: EdgeInsets

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        label
            .padding(insets)
            .frame(minWidth: 28, minHeight: 28)
            .foregroundStyle(isProminent ? prominentForegroundColor : Color.primary)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            }
            .scaleEffect(isPressed && isEnabled && !reduceMotion ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = isEnabled && $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isPressed)
    }

    private var backgroundColor: Color {
        guard isEnabled else { return .clear }
        if isProminent {
            if isPressed { return Color.accentColor.opacity(0.78) }
            if isHovered { return Color.accentColor.opacity(0.9) }
            return Color.accentColor
        }
        if isPressed { return Color.accentColor.opacity(0.22) }
        if isSelected { return Color.accentColor.opacity(isHovered ? 0.17 : 0.11) }
        if isHovered { return Color.primary.opacity(0.08) }
        return .clear
    }

    private var prominentForegroundColor: Color {
        guard isEnabled else { return .primary }

        guard let accent = NSColor(Color.accentColor).usingColorSpace(.deviceRGB) else {
            return colorScheme == .dark ? .white : .black
        }

        let canvas = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)
        let fallbackCanvas: CGFloat = colorScheme == .dark ? 0.12 : 1.0
        let canvasRed = canvas?.redComponent ?? fallbackCanvas
        let canvasGreen = canvas?.greenComponent ?? fallbackCanvas
        let canvasBlue = canvas?.blueComponent ?? fallbackCanvas
        let alpha: CGFloat = isPressed ? 0.78 : (isHovered ? 0.9 : 1.0)
        let red = accent.redComponent * alpha + canvasRed * (1 - alpha)
        let green = accent.greenComponent * alpha + canvasGreen * (1 - alpha)
        let blue = accent.blueComponent * alpha + canvasBlue * (1 - alpha)
        let luminance = 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)

        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast ? .black : .white
    }

    private func linearized(_ component: CGFloat) -> Double {
        let value = Double(min(max(component, 0), 1))
        return value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }
}
