//
//  MarkdownEditorTheme.swift
//  YoPDFCore
//
//  Created for Task P0-C-A: Native Markdown Editor.
//  Apache-2.0 Open Source License.
//

import AppKit
import Foundation

/// Underlying AppKit text layout engine preference.
///
/// YoPDF defaults to TextKit 2 (`NSTextLayoutManager`) and exposes `.textKit1`
/// as an explicit fallback seam if any OS/IME edge case requires it.
public enum MarkdownTextEngine: String, Sendable, Equatable, CaseIterable {
    case textKit2
    case textKit1
}

/// Appearance policy for `MarkdownEditorView`.
public enum MarkdownColorTheme: String, Sendable, Equatable, CaseIterable {
    case system
    case light
    case dark
}

/// Padding applied around the text container inside `MarkdownEditorView`.
public struct MarkdownContentInsets: Equatable, Sendable {
    public var horizontal: CGFloat
    public var vertical: CGFloat

    public init(horizontal: CGFloat = 24, vertical: CGFloat = 20) {
        self.horizontal = max(0, horizontal)
        self.vertical = max(0, vertical)
    }

    public static let `default` = MarkdownContentInsets()
}

/// Immutable configuration passed into `MarkdownEditorView`.
public struct MarkdownEditorConfiguration: Equatable, Sendable {
    public var theme: MarkdownColorTheme
    public var fontSize: CGFloat
    public var lineHeightMultiple: CGFloat
    public var contentInsets: MarkdownContentInsets
    public var isEditable: Bool
    public var isSelectable: Bool
    public var wrapsLines: Bool
    public var preferredEngine: MarkdownTextEngine
    public var continuousSpellCheckingEnabled: Bool

    public init(
        theme: MarkdownColorTheme = .system,
        fontSize: CGFloat = 14,
        lineHeightMultiple: CGFloat = 1.45,
        contentInsets: MarkdownContentInsets = .default,
        isEditable: Bool = true,
        isSelectable: Bool = true,
        wrapsLines: Bool = true,
        preferredEngine: MarkdownTextEngine = .textKit2,
        continuousSpellCheckingEnabled: Bool = false
    ) {
        self.theme = theme
        self.fontSize = min(max(fontSize, 10), 32)
        self.lineHeightMultiple = min(max(lineHeightMultiple, 1.0), 2.2)
        self.contentInsets = contentInsets
        self.isEditable = isEditable
        self.isSelectable = isSelectable
        self.wrapsLines = wrapsLines
        self.preferredEngine = preferredEngine
        self.continuousSpellCheckingEnabled = continuousSpellCheckingEnabled
    }

    public static let `default` = MarkdownEditorConfiguration()
}

/// Resolved fonts, colors, and paragraph metrics for a concrete Light/Dark theme.
@MainActor
public struct MarkdownEditorPalette: Equatable {
    public struct Signature: Equatable, Hashable, Sendable {
        public let isDark: Bool
        public let baseFontSize: CGFloat
        public let lineHeightMultiple: CGFloat
    }

    public let isDark: Bool
    public let baseFontSize: CGFloat
    public let lineHeightMultiple: CGFloat
    nonisolated public let signature: Signature

    nonisolated public static func == (lhs: MarkdownEditorPalette, rhs: MarkdownEditorPalette) -> Bool {
        lhs.signature == rhs.signature
    }

    // MARK: - Colors

    public let editorBackground: NSColor
    public let bodyText: NSColor
    public let secondaryText: NSColor
    public let syntaxMarker: NSColor
    public let headingText: NSColor
    public let codeText: NSColor
    public let codeBackground: NSColor
    public let inlineCodeBackground: NSColor
    public let codeLanguage: NSColor
    public let linkText: NSColor
    public let linkURL: NSColor
    public let blockquoteMarker: NSColor
    public let blockquoteText: NSColor
    public let listMarker: NSColor
    public let frontmatterKey: NSColor
    public let frontmatterValue: NSColor
    public let insertionPoint: NSColor

    // MARK: - Fonts

    public let bodyFont: NSFont
    public let boldBodyFont: NSFont
    public let italicBodyFont: NSFont
    public let boldItalicBodyFont: NSFont
    public let codeFont: NSFont
    public let boldCodeFont: NSFont

    public let h1Font: NSFont
    public let h2Font: NSFont
    public let h3Font: NSFont
    public let h4PlusFont: NSFont

    public let defaultParagraphStyle: NSParagraphStyle

    public static func resolved(
        theme: MarkdownColorTheme,
        appearance: NSAppearance?,
        fontSize: CGFloat,
        lineHeightMultiple: CGFloat
    ) -> MarkdownEditorPalette {
        let isDark: Bool
        switch theme {
        case .light:
            isDark = false
        case .dark:
            isDark = true
        case .system:
            let effective = appearance ?? NSApp?.effectiveAppearance
            isDark = effective?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return MarkdownEditorPalette(
            isDark: isDark,
            baseFontSize: min(max(fontSize, 10), 32),
            lineHeightMultiple: min(max(lineHeightMultiple, 1.0), 2.2)
        )
    }

    public init(isDark: Bool, baseFontSize: CGFloat = 14, lineHeightMultiple: CGFloat = 1.45) {
        self.isDark = isDark
        self.baseFontSize = baseFontSize
        self.lineHeightMultiple = lineHeightMultiple
        self.signature = Signature(
            isDark: isDark,
            baseFontSize: baseFontSize,
            lineHeightMultiple: lineHeightMultiple
        )

        if isDark {
            editorBackground = NSColor(srgbRed: 0.118, green: 0.122, blue: 0.133, alpha: 1.0)
            bodyText = NSColor(srgbRed: 0.929, green: 0.933, blue: 0.945, alpha: 1.0)
            secondaryText = NSColor(srgbRed: 0.635, green: 0.643, blue: 0.678, alpha: 1.0)
            syntaxMarker = NSColor(srgbRed: 0.455, green: 0.467, blue: 0.510, alpha: 1.0)
            headingText = NSColor(srgbRed: 0.980, green: 0.984, blue: 0.992, alpha: 1.0)
            codeText = NSColor(srgbRed: 0.878, green: 0.902, blue: 0.937, alpha: 1.0)
            codeBackground = NSColor(srgbRed: 0.165, green: 0.173, blue: 0.192, alpha: 1.0)
            inlineCodeBackground = NSColor(srgbRed: 0.192, green: 0.200, blue: 0.224, alpha: 1.0)
            codeLanguage = NSColor(srgbRed: 0.557, green: 0.592, blue: 0.651, alpha: 1.0)
            linkText = NSColor(srgbRed: 0.365, green: 0.659, blue: 0.988, alpha: 1.0)
            linkURL = NSColor(srgbRed: 0.510, green: 0.557, blue: 0.627, alpha: 1.0)
            blockquoteMarker = NSColor(srgbRed: 0.420, green: 0.627, blue: 0.969, alpha: 1.0)
            blockquoteText = NSColor(srgbRed: 0.725, green: 0.737, blue: 0.776, alpha: 1.0)
            listMarker = NSColor(srgbRed: 0.365, green: 0.659, blue: 0.988, alpha: 1.0)
            frontmatterKey = NSColor(srgbRed: 0.396, green: 0.835, blue: 0.761, alpha: 1.0)
            frontmatterValue = NSColor(srgbRed: 0.694, green: 0.706, blue: 0.737, alpha: 1.0)
            insertionPoint = NSColor(srgbRed: 0.949, green: 0.953, blue: 0.965, alpha: 1.0)
        } else {
            editorBackground = NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1.0)
            bodyText = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1.0)
            secondaryText = NSColor(srgbRed: 0.369, green: 0.369, blue: 0.400, alpha: 1.0)
            syntaxMarker = NSColor(srgbRed: 0.588, green: 0.588, blue: 0.627, alpha: 1.0)
            headingText = NSColor(srgbRed: 0.067, green: 0.067, blue: 0.075, alpha: 1.0)
            codeText = NSColor(srgbRed: 0.165, green: 0.204, blue: 0.251, alpha: 1.0)
            codeBackground = NSColor(srgbRed: 0.953, green: 0.957, blue: 0.969, alpha: 1.0)
            inlineCodeBackground = NSColor(srgbRed: 0.937, green: 0.941, blue: 0.953, alpha: 1.0)
            codeLanguage = NSColor(srgbRed: 0.420, green: 0.447, blue: 0.502, alpha: 1.0)
            linkText = NSColor(srgbRed: 0.039, green: 0.400, blue: 0.761, alpha: 1.0)
            linkURL = NSColor(srgbRed: 0.478, green: 0.525, blue: 0.600, alpha: 1.0)
            blockquoteMarker = NSColor(srgbRed: 0.239, green: 0.475, blue: 0.898, alpha: 1.0)
            blockquoteText = NSColor(srgbRed: 0.290, green: 0.290, blue: 0.322, alpha: 1.0)
            listMarker = NSColor(srgbRed: 0.039, green: 0.400, blue: 0.761, alpha: 1.0)
            frontmatterKey = NSColor(srgbRed: 0.059, green: 0.463, blue: 0.431, alpha: 1.0)
            frontmatterValue = NSColor(srgbRed: 0.341, green: 0.325, blue: 0.306, alpha: 1.0)
            insertionPoint = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1.0)
        }

        let fontManager = NSFontManager.shared
        let regularBody = NSFont.systemFont(ofSize: baseFontSize, weight: .regular)
        let boldBody = NSFont.systemFont(ofSize: baseFontSize, weight: .semibold)
        self.bodyFont = regularBody
        self.boldBodyFont = boldBody
        self.italicBodyFont = fontManager.convert(regularBody, toHaveTrait: .italicFontMask)
        self.boldItalicBodyFont = fontManager.convert(boldBody, toHaveTrait: .italicFontMask)

        let codeSize = max(10, baseFontSize - 1)
        self.codeFont = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        self.boldCodeFont = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .semibold)

        self.h1Font = NSFont.systemFont(ofSize: baseFontSize + 5, weight: .bold)
        self.h2Font = NSFont.systemFont(ofSize: baseFontSize + 3, weight: .bold)
        self.h3Font = NSFont.systemFont(ofSize: baseFontSize + 1.5, weight: .semibold)
        self.h4PlusFont = NSFont.systemFont(ofSize: baseFontSize, weight: .semibold)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeightMultiple
        self.defaultParagraphStyle = paragraph.copy() as! NSParagraphStyle
    }

    public func headingFont(level: Int) -> NSFont {
        switch level {
        case 1: return h1Font
        case 2: return h2Font
        case 3: return h3Font
        default: return h4PlusFont
        }
    }

    public var baseTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: bodyText,
            .paragraphStyle: defaultParagraphStyle,
        ]
    }
}
