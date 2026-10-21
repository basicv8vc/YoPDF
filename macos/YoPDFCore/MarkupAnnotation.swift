import AppKit
import PDFKit

/// The markup annotations YoPDF can create and edit in P2b.
///
/// Both kinds are standard PDF annotations. The enum deliberately excludes
/// StrikeOut, notes and free text: P2b PR 1 is about the two text markup tools
/// that already share PDFKit's selection geometry.
public enum MarkupKind: String, CaseIterable, Hashable, Sendable {
    case highlight
    case underline

    public var title: String {
        switch self {
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        }
    }

    public var actionTitle: String {
        "\(title) Selection"
    }

    public var symbolName: String {
        switch self {
        case .highlight: return "highlighter"
        case .underline: return "underline"
        }
    }

    /// The PDF annotation subtype written to the file.
    public var annotationSubtype: PDFAnnotationSubtype {
        switch self {
        case .highlight: return .highlight
        case .underline: return .underline
        }
    }

    public var defaultColorHex: String {
        switch self {
        case .highlight: return MarkupColorPalette.defaultHighlightHex
        case .underline: return MarkupColorPalette.defaultUnderlineHex
        }
    }

    /// The other markup subtype, for the "Convert" action.
    public var converted: MarkupKind {
        switch self {
        case .highlight: return .underline
        case .underline: return .highlight
        }
    }

    public init?(annotation: PDFAnnotation) {
        switch annotation.type ?? "" {
        case "Highlight":
            self = .highlight
        case "Underline":
            self = .underline
        default:
            return nil
        }
    }
}

public struct MarkupColorPreset: Identifiable, Hashable, Sendable {
    public let name: String
    public let hex: String

    public var id: String { hex }

    public var color: NSColor {
        MarkupColorPalette.color(fromHex: hex)
    }
}

/// The six presets shared by Highlight and Underline, plus colour normalization.
///
/// PDFKit serializes an annotation's `/C` entry as RGB only. An `NSColor` with
/// alpha 0.45 reads back with alpha 1 after a save/reopen round trip, so YoPDF
/// stores opaque presets. PDFKit paints a highlight behind the glyphs, so black
/// text stays legible without relying on an alpha value that the file cannot
/// preserve. The alpha of a chosen colour is never used as the stored truth, and
/// a fully transparent choice is rejected rather than silently becoming black or
/// falling back to a preset.
public enum MarkupColorPalette {
    public static let defaultHighlightHex = "FFD60A"
    public static let defaultUnderlineHex = "007AFF"

    public static let presets: [MarkupColorPreset] = [
        MarkupColorPreset(name: "Yellow", hex: "FFD60A"),
        MarkupColorPreset(name: "Green", hex: "34C759"),
        MarkupColorPreset(name: "Blue", hex: "007AFF"),
        MarkupColorPreset(name: "Pink", hex: "FF2D55"),
        MarkupColorPreset(name: "Purple", hex: "AF52DE"),
        MarkupColorPreset(name: "Orange", hex: "FF9500")
    ]

    public static func preset(hex: String) -> MarkupColorPreset? {
        presets.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }
    }

    /// An sRGB colour from a six-digit hex string. Invalid input falls back to
    /// the supplied preset rather than producing an invisible annotation.
    public static func color(
        fromHex hex: String,
        alpha: CGFloat = 1,
        fallbackHex: String = defaultHighlightHex
    ) -> NSColor {
        let rgb = srgbColor(fromHex: hex)
            ?? srgbColor(fromHex: fallbackHex)
            ?? NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
        return rgb.withAlphaComponent(alpha)
    }

    /// Parses RRGGBB without consulting any fallback.
    ///
    /// `Scanner` is used rather than `UInt32(_:radix:)` so that a leading `#`
    /// or stray separator does not change which six digits are significant.
    private static func srgbColor(fromHex hex: String) -> NSColor? {
        let digits = hex.filter(\.isHexDigit)
        guard digits.count == 6 else { return nil }
        var packed: UInt64 = 0
        guard Scanner(string: digits).scanHexInt64(&packed) else { return nil }
        return NSColor(
            srgbRed: CGFloat((packed >> 16) & 0xFF) / 255,
            green: CGFloat((packed >> 8) & 0xFF) / 255,
            blue: CGFloat(packed & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Uppercase RRGGBB, independent of the source colour space.
    public static func hex(from color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB),
              rgb.redComponent.isFinite, rgb.greenComponent.isFinite, rgb.blueComponent.isFinite
        else { return nil }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        return channels
            .map { String(format: "%02X", Int(($0 * 255).rounded())) }
            .joined()
    }

    /// Returns an opaque, finite sRGB colour, or nil when the input is
    /// transparent or cannot be converted to RGB.
    public static func normalized(_ color: NSColor) -> NSColor? {
        guard color.alphaComponent > 0.001,
              let rgb = color.usingColorSpace(.sRGB),
              rgb.redComponent.isFinite,
              rgb.greenComponent.isFinite,
              rgb.blueComponent.isFinite,
              rgb.alphaComponent > 0.001
        else { return nil }
        // Clamp rather than trusting a custom colour space to stay in 0...1.
        func component(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
        return NSColor(
            srgbRed: component(rgb.redComponent),
            green: component(rgb.greenComponent),
            blue: component(rgb.blueComponent),
            alpha: 1
        )
    }

    /// The colour written to the PDF. Both subtypes store RGB; PDFKit draws the
    /// highlight behind the text and the underline as a separate stroke.
    public static func annotationColor(_ color: NSColor, for kind: MarkupKind) -> NSColor {
        normalized(color) ?? Self.color(fromHex: kind.defaultColorHex)
    }

    public static func color(
        forHex hex: String?,
        fallback: MarkupKind
    ) -> NSColor {
        if let hex, let parsed = srgbColor(fromHex: hex) {
            return parsed
        }
        return color(fromHex: fallback.defaultColorHex)
    }
}

/// UserDefaults-backed defaults for the two markup tools.
///
/// The keys are YoPDF's own and nothing else's preference namespace is read or
/// written. Importing another app's defaults would make its private storage a
/// compatibility contract YoPDF never agreed to.
public struct MarkupColorPreferences {
    public static let highlightColorKey = "dev.yopdf.markup.highlightColorHex"
    public static let underlineColorKey = "dev.yopdf.markup.underlineColorHex"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func key(for kind: MarkupKind) -> String {
        switch kind {
        case .highlight: return highlightColorKey
        case .underline: return underlineColorKey
        }
    }

    @MainActor
    public func color(for kind: MarkupKind) -> NSColor {
        MarkupColorPalette.color(
            forHex: defaults.string(forKey: Self.key(for: kind)),
            fallback: kind
        )
    }

    @MainActor
    @discardableResult
    public func setColor(_ color: NSColor, for kind: MarkupKind) -> Bool {
        guard let normalized = MarkupColorPalette.normalized(color),
              let hex = MarkupColorPalette.hex(from: normalized)
        else { return false }
        defaults.set(hex, forKey: Self.key(for: kind))
        return true
    }
}

/// PDF annotation permission bits, read from `/F`.
///
/// The raw bits are used because `PDFAnnotation.isReadOnly` describes widget
/// fields rather than this dictionary entry. ReadOnly (bit 7) and Locked (bit 8)
/// protect markup properties and deletion. LockedContents (bit 10) only protects
/// `/Contents`; PR 1 does not edit contents, but the helper stays here so the
/// Note work can reuse it.
@MainActor
public enum MarkupPermissions {
    public static let readOnlyFlag = 1 << 6
    public static let lockedFlag = 1 << 7
    public static let lockedContentsFlag = 1 << 9

    public static func flags(of annotation: PDFAnnotation) -> Int {
        (annotation.value(forAnnotationKey: .flags) as? NSNumber)?.intValue ?? 0
    }

    public static func allowsPropertyChanges(_ annotation: PDFAnnotation) -> Bool {
        let flags = flags(of: annotation)
        return flags & (readOnlyFlag | lockedFlag) == 0
    }

    public static func allowsContentsChanges(_ annotation: PDFAnnotation) -> Bool {
        allowsPropertyChanges(annotation)
            && flags(of: annotation) & lockedContentsFlag == 0
    }

    /// The checks that do not depend on the annotation still being attached.
    ///
    /// Undo and Redo also add annotations that are currently detached (an undo
    /// of a delete, or a redo of an insert), so attachment is validated by the
    /// caller. The document-level commenting permission and the annotation's
    /// own `/F` flags apply either way.
    public static func allowsAnnotationChanges(
        _ annotation: PDFAnnotation,
        in document: PDFDocument
    ) -> Bool {
        document.allowsCommenting && allowsPropertyChanges(annotation)
    }

    public static func canModify(
        _ annotation: PDFAnnotation,
        in document: PDFDocument,
        on page: PDFPage
    ) -> Bool {
        allowsAnnotationChanges(annotation, in: document)
            && page.document === document
            && annotation.page === page
            && page.annotations.contains(where: { $0 === annotation })
    }
}

/// Enough state for the UI to draw and edit one selected markup annotation.
///
/// `quadRects` are page-space rectangles. The annotation itself stays internal
/// so a SwiftUI view cannot mutate PDFKit behind the model's back; all edits go
/// through `PDFDocumentModel`.
public struct MarkupSelection: Equatable, Identifiable {
    public let kind: MarkupKind
    public let pageIndex: Int
    public let quadRects: [CGRect]
    public let color: NSColor

    let annotation: PDFAnnotation

    public var id: ObjectIdentifier { ObjectIdentifier(annotation) }

    @MainActor
    init?(annotation: PDFAnnotation, kind: MarkupKind, pageIndex: Int) {
        guard let color = MarkupColorPalette.hex(from: annotation.color) else { return nil }
        self.annotation = annotation
        self.kind = kind
        self.pageIndex = pageIndex
        self.quadRects = MarkupGeometry.quadRects(for: annotation)
        self.color = MarkupColorPalette.color(fromHex: color)
    }

    public static func == (lhs: MarkupSelection, rhs: MarkupSelection) -> Bool {
        lhs.annotation === rhs.annotation
            && lhs.kind == rhs.kind
            && lhs.pageIndex == rhs.pageIndex
    }
}

@MainActor
public enum MarkupGeometry {
    /// Page-space rectangles for the painted quads of an annotation.
    ///
    /// PDFKit exposes `quadrilateralPoints` relative to the annotation's bounds
    /// origin. Reading them back does the same, even after a save; the points are
    /// converted to page space here. A malformed or missing quad list falls back
    /// to the bounds rectangle, which is the best available geometry for a
    /// third-party annotation that never wrote `/QuadPoints`.
    public static func quadRects(for annotation: PDFAnnotation) -> [CGRect] {
        let origin = annotation.bounds.origin
        let points = annotation.quadrilateralPoints ?? []
        guard !points.isEmpty, points.count.isMultiple(of: 4) else {
            return [annotation.bounds]
        }

        var rects: [CGRect] = []
        rects.reserveCapacity(points.count / 4)
        var index = 0
        while index < points.count {
            var minX = CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude
            for offset in 0..<4 {
                let point = points[index + offset].pointValue
                guard point.x.isFinite, point.y.isFinite else {
                    return [annotation.bounds]
                }
                let pagePoint = CGPoint(x: point.x + origin.x, y: point.y + origin.y)
                minX = min(minX, pagePoint.x)
                minY = min(minY, pagePoint.y)
                maxX = max(maxX, pagePoint.x)
                maxY = max(maxY, pagePoint.y)
            }
            if maxX > minX, maxY > minY {
                rects.append(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            }
            index += 4
        }
        return rects.isEmpty ? [annotation.bounds] : rects
    }

    /// True only when `point` falls inside a painted quad.
    ///
    /// This is the hit-testing rule that keeps the empty gap inside a
    /// multi-line annotation's bounding box from selecting the annotation.
    public static func contains(_ annotation: PDFAnnotation, point: CGPoint) -> Bool {
        guard annotation.bounds.contains(point) else { return false }
        return quadRects(for: annotation).contains { $0.contains(point) }
    }

    /// A per-line selection only counts for a context menu when the click is
    /// actually inside one of its line rectangles on this page.
    public static func contains(
        _ selection: PDFSelection,
        point: CGPoint,
        on page: PDFPage
    ) -> Bool {
        guard (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              selection.pages.contains(where: { $0 === page })
        else { return false }

        var lines = selection.selectionsByLine()
        if lines.isEmpty {
            lines = [selection]
        }
        return lines.contains { line in
            line.pages.contains(where: { $0 === page })
                && line.bounds(for: page).contains(point)
        }
    }
}
