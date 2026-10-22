import AppKit
import PDFKit

/// The six paper tints YoPDF paints behind a note marker.
///
/// The value is stored as an optional custom annotation key. A missing or
/// unreadable key only loses the tint: the note body lives in the standard
/// `/Contents` entry and remains readable by every PDF reader.
public enum NotePaperColor: String, CaseIterable, Hashable, Sendable {
    case honey
    case rose
    case mint
    case sky
    case lavender
    case sand

    public var title: String {
        switch self {
        case .honey: return "Honey"
        case .rose: return "Rose"
        case .mint: return "Mint"
        case .sky: return "Sky"
        case .lavender: return "Lavender"
        case .sand: return "Sand"
        }
    }

    /// Uppercase RRGGBB for `/C` and the custom style key.
    public var hex: String {
        switch self {
        case .honey: return "FFEDA6"
        case .rose: return "FFD9D9"
        case .mint: return "CCEDD4"
        case .sky: return "CFE6FA"
        case .lavender: return "E3D9F7"
        case .sand: return "F0E6D1"
        }
    }

    @MainActor
    public var color: NSColor {
        MarkupColorPalette.color(fromHex: hex, fallbackHex: NotePaperColor.honey.hex)
    }
}

/// A note that is being composed but is not in the document yet.
///
/// The anchor is captured when the composer opens, not when Save is pressed.
/// That is what keeps a cross-page selection on an explicit page and stops a
/// page note from inheriting a text selection that was still live in the view.
public struct NoteDraft: Equatable, Identifiable {
    public let id: UUID
    public let pageIndex: Int
    /// Marker rectangle in page space.
    public let bounds: CGRect
    /// A short, whitespace-collapsed copy of the selected text, if any.
    public let excerpt: String?
    public let isPageLevel: Bool

    /// The document the anchor was captured in. A draft cannot be committed
    /// into a document that replaced it while the composer was open.
    let documentIdentifier: ObjectIdentifier

    /// 1-based page label for the composer header.
    public var pageLabel: String { "Page \(pageIndex + 1)" }

    init(
        pageIndex: Int,
        bounds: CGRect,
        excerpt: String?,
        isPageLevel: Bool,
        document: PDFDocument
    ) {
        self.id = UUID()
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.excerpt = excerpt
        self.isPageLevel = isPageLevel
        self.documentIdentifier = ObjectIdentifier(document)
    }
}

/// What the page overlay needs to draw one marker.
public struct NoteMarker: Identifiable, Equatable {
    public let id: ObjectIdentifier
    public let pageIndex: Int
    public let bounds: CGRect
    public let paperColor: NotePaperColor

    init(annotation: PDFAnnotation, pageIndex: Int, bounds: CGRect, paperColor: NotePaperColor) {
        self.id = ObjectIdentifier(annotation)
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.paperColor = paperColor
    }
}

/// The note the user clicked, in the terms the composer needs.
///
/// The `PDFAnnotation` stays internal so a SwiftUI view cannot mutate PDFKit
/// behind the model's back; every edit goes through `PDFDocumentModel`.
public struct NoteSelection: Identifiable, Equatable {
    public let pageIndex: Int
    public let bounds: CGRect
    public let contents: String
    public let paperColor: NotePaperColor
    public let excerpt: String?
    public let isPageLevel: Bool

    let annotation: PDFAnnotation

    public var id: ObjectIdentifier { ObjectIdentifier(annotation) }

    /// 1-based page label for the composer header.
    public var pageLabel: String { "Page \(pageIndex + 1)" }

    init(
        annotation: PDFAnnotation,
        pageIndex: Int,
        bounds: CGRect,
        contents: String,
        paperColor: NotePaperColor,
        excerpt: String?,
        isPageLevel: Bool
    ) {
        self.annotation = annotation
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.contents = contents
        self.paperColor = paperColor
        self.excerpt = excerpt
        self.isPageLevel = isPageLevel
    }

    public static func == (lhs: NoteSelection, rhs: NoteSelection) -> Bool {
        lhs.annotation === rhs.annotation
            && lhs.pageIndex == rhs.pageIndex
            && lhs.bounds == rhs.bounds
            && lhs.contents == rhs.contents
            && lhs.paperColor == rhs.paperColor
            && lhs.excerpt == rhs.excerpt
            && lhs.isPageLevel == rhs.isPageLevel
    }
}

/// What the annotation's own `/F` flags and the document allow on one note.
///
/// The three capabilities are separate on purpose. ReadOnly (bit 7) and Locked
/// (bit 8) protect every property including deletion; LockedContents (bit 10)
/// protects only `/Contents`, so a locked-body note can still be recoloured or
/// deleted — the body is what the other application wanted to preserve.
public struct NotePermissions: Equatable, Sendable {
    public let canEditContents: Bool
    public let canChangeStyle: Bool
    public let canDelete: Bool

    public init(canEditContents: Bool, canChangeStyle: Bool, canDelete: Bool) {
        self.canEditContents = canEditContents
        self.canChangeStyle = canChangeStyle
        self.canDelete = canDelete
    }

    public static let none = NotePermissions(
        canEditContents: false,
        canChangeStyle: false,
        canDelete: false
    )

    /// Nothing can be changed, so the composer is a viewer.
    public var isReadOnly: Bool { !canEditContents && !canChangeStyle && !canDelete }

    /// Only the body is protected: the paper colour and deletion still work.
    public var isContentsLocked: Bool { !canEditContents && canChangeStyle }
}

/// Creation, reading and style storage for standard PDF `/Text` annotations.
///
/// The body is always `/Contents`. Paper colour and the optional quote are
/// separate custom keys, so losing either cannot hide the text. No sidecar or
/// database is involved: a saved PDF is the whole document.
@MainActor
public enum NoteService {

    public static let markerSize: CGFloat = 22
    /// The custom keys are deliberately namespaced and optional.
    ///
    /// PDF annotation keys are written with their leading slash, exactly like
    /// `/Contents`; `PDFAnnotationKey` compares the raw string, so a key without
    /// it would be written but never read back.
    static let paperColorKey = PDFAnnotationKey(rawValue: "/YoPDFNotePaper")
    static let excerptKey = PDFAnnotationKey(rawValue: "/YoPDFNoteExcerpt")
    static let pageLevelKey = PDFAnnotationKey(rawValue: "/YoPDFNotePageLevel")

    public static func isTextAnnotation(_ annotation: PDFAnnotation) -> Bool {
        guard let type = annotation.type else { return false }
        return type == "Text" || type == "/Text"
    }

    // MARK: - Reading

    public static func paperColor(of annotation: PDFAnnotation) -> NotePaperColor {
        if let raw = annotation.value(forAnnotationKey: paperColorKey) as? String,
           let color = NotePaperColor(rawValue: raw) {
            return color
        }
        // A third-party note has no YoPDF style key. If its standard `/C`
        // happens to match a paper preset, showing that tint is a helpful
        // fallback; otherwise the note is shown on Honey.
        if let hex = MarkupColorPalette.hex(from: annotation.color),
           let color = NotePaperColor.allCases.first(where: {
               $0.hex.caseInsensitiveCompare(hex) == .orderedSame
           }) {
            return color
        }
        return .honey
    }

    public static func excerpt(of annotation: PDFAnnotation) -> String? {
        guard let raw = annotation.value(forAnnotationKey: excerptKey) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func isPageLevel(_ annotation: PDFAnnotation) -> Bool {
        if let raw = annotation.value(forAnnotationKey: pageLevelKey) as? String {
            return raw == "1" || raw.caseInsensitiveCompare("true") == .orderedSame
        }
        return excerpt(of: annotation) == nil
    }

    /// Marker geometry in page space.
    ///
    /// A malformed third-party note with an empty rectangle still gets a
    /// visible marker at the page centre rather than disappearing entirely.
    public static func resolvedBounds(
        for annotation: PDFAnnotation,
        on page: PDFPage
    ) -> CGRect {
        let bounds = annotation.bounds
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 1, bounds.height > 1
        else {
            return markerBounds(
                center: CGPoint(
                    x: page.bounds(for: .cropBox).midX,
                    y: page.bounds(for: .cropBox).midY
                ),
                in: page.bounds(for: .cropBox)
            )
        }
        return bounds
    }

    public static func selection(
        for annotation: PDFAnnotation,
        on page: PDFPage,
        pageIndex: Int
    ) -> NoteSelection? {
        guard isTextAnnotation(annotation),
              annotation.shouldDisplay,
              page.document != nil
        else { return nil }

        return NoteSelection(
            annotation: annotation,
            pageIndex: pageIndex,
            bounds: resolvedBounds(for: annotation, on: page),
            contents: annotation.contents ?? "",
            paperColor: paperColor(of: annotation),
            excerpt: excerpt(of: annotation),
            isPageLevel: isPageLevel(annotation)
        )
    }

    /// Every visible standard `/Text` annotation, for the page overlays.
    ///
    /// Popup annotations are skipped: they are PDFKit's companion object for a
    /// note, not a second note.
    public static func markers(in document: PDFDocument) -> [NoteMarker] {
        var markers: [NoteMarker] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where isTextAnnotation(annotation) {
                guard annotation.shouldDisplay else { continue }
                markers.append(NoteMarker(
                    annotation: annotation,
                    pageIndex: pageIndex,
                    bounds: resolvedBounds(for: annotation, on: page),
                    paperColor: paperColor(of: annotation)
                ))
            }
        }
        return markers
    }

    /// The click target is slightly larger than the drawn marker so a small
    /// third-party note is still comfortable to hit.
    public static func hitRect(for annotation: PDFAnnotation, on page: PDFPage) -> CGRect {
        resolvedBounds(for: annotation, on: page)
            .insetBy(dx: -4, dy: -4)
    }

    public static func hitTest(
        _ point: CGPoint,
        on page: PDFPage,
        in document: PDFDocument
    ) -> Bool {
        guard page.document === document else { return false }
        return page.annotations.contains { annotation in
            isTextAnnotation(annotation)
                && annotation.shouldDisplay
                && hitRect(for: annotation, on: page).contains(point)
        }
    }

    /// The capabilities of one note right now.
    ///
    /// Re-read on every call rather than cached: another application can change
    /// `/F` between opening the composer and pressing Save.
    public static func permissions(
        for annotation: PDFAnnotation,
        in document: PDFDocument
    ) -> NotePermissions {
        guard document.allowsCommenting,
              let page = annotation.page,
              page.document === document
        else { return .none }

        let properties = MarkupPermissions.allowsPropertyChanges(annotation)
        return NotePermissions(
            canEditContents: properties && MarkupPermissions.allowsContentsChanges(annotation),
            canChangeStyle: properties,
            canDelete: properties
        )
    }

    // MARK: - Drafts

    /// Captures a note anchored next to the selected text.
    ///
    /// A cross-page selection is anchored on the lowest document page that has
    /// usable line geometry. The note is never written to a page the selection
    /// merely passed through, and never to the page that happened to be current
    /// when the composer opened.
    public static func draft(
        from selection: PDFSelection,
        in document: PDFDocument
    ) -> NoteDraft? {
        let text = normalizedExcerpt(selection.string)
        guard !text.isEmpty else { return nil }

        let groups = pageGroups(for: selection, in: document)
        guard let first = groups.first else { return nil }
        let pageBounds = first.page.bounds(for: .cropBox)
        let union = first.rects.dropFirst().reduce(first.rects[0]) { $0.union($1) }
        let bounds = markerBounds(adjacentTo: union, in: pageBounds)

        return NoteDraft(
            pageIndex: first.index,
            bounds: bounds,
            excerpt: String(text.prefix(240)),
            isPageLevel: false,
            document: document
        )
    }

    /// Captures a page-level note at a click point, without consulting any
    /// selection.
    public static func draft(
        at point: CGPoint,
        on page: PDFPage,
        in document: PDFDocument
    ) -> NoteDraft? {
        guard page.document === document else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return nil }

        let pageBounds = page.bounds(for: .cropBox)
        return NoteDraft(
            pageIndex: pageIndex,
            bounds: markerBounds(center: point, in: pageBounds),
            excerpt: nil,
            isPageLevel: true,
            document: document
        )
    }

    // MARK: - Creating

    public static func annotation(
        for draft: NoteDraft,
        contents: String,
        paperColor: NotePaperColor
    ) -> PDFAnnotation? {
        let text = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let annotation = PDFAnnotation(
            bounds: draft.bounds,
            forType: .text,
            withProperties: nil
        )
        annotation.iconType = .comment
        annotation.contents = text
        annotation.userName = "YoPDF"
        annotation.modificationDate = Date()
        // No `/NM` (annotation name) is written: PDFKit accepts one in memory
        // but drops it on serialisation, so a note is identified by the object
        // that owns it rather than by a name the file would not keep.
        setPaperColor(paperColor, on: annotation)
        setExcerpt(draft.excerpt, on: annotation)
        setPageLevel(draft.isPageLevel, on: annotation)
        return annotation
    }

    /// Applies the YoPDF paper tint. `/C` is also updated so the standard note
    /// icon is not visually unrelated to the marker.
    public static func setPaperColor(_ color: NotePaperColor, on annotation: PDFAnnotation) {
        annotation.color = color.color
        _ = annotation.setValue(color.rawValue, forAnnotationKey: paperColorKey)
    }

    public static func setContents(_ contents: String?, on annotation: PDFAnnotation) {
        let trimmed = contents?.trimmingCharacters(in: .whitespacesAndNewlines)
        annotation.contents = (trimmed?.isEmpty ?? true) ? nil : trimmed
        annotation.modificationDate = Date()
    }

    public static func setExcerpt(_ excerpt: String?, on annotation: PDFAnnotation) {
        if let excerpt, !excerpt.isEmpty {
            _ = annotation.setValue(excerpt, forAnnotationKey: excerptKey)
        } else {
            annotation.removeValue(forAnnotationKey: excerptKey)
        }
    }

    private static func setPageLevel(_ isPageLevel: Bool, on annotation: PDFAnnotation) {
        _ = annotation.setValue(isPageLevel ? "1" : "0", forAnnotationKey: pageLevelKey)
    }

    // MARK: - Geometry

    public static func markerBounds(center: CGPoint, in pageBounds: CGRect) -> CGRect {
        let half = markerSize / 2
        let minX = pageBounds.minX + half + 2
        let maxX = pageBounds.maxX - half - 2
        let minY = pageBounds.minY + half + 2
        let maxY = pageBounds.maxY - half - 2

        // A pathologically small page still needs a finite rectangle.
        let centerX = minX <= maxX ? min(max(center.x, minX), maxX) : pageBounds.midX
        let centerY = minY <= maxY ? min(max(center.y, minY), maxY) : pageBounds.midY
        return CGRect(
            x: centerX - half,
            y: centerY - half,
            width: markerSize,
            height: markerSize
        )
    }

    /// Places the marker just outside the top-right of the selected text, or
    /// to its left when the right margin is too narrow.
    public static func markerBounds(adjacentTo rect: CGRect, in pageBounds: CGRect) -> CGRect {
        let half = markerSize / 2
        let gap: CGFloat = 6

        var x = rect.maxX + gap + half
        if x + half > pageBounds.maxX - 2 {
            x = rect.minX - gap - half
        }

        let y = rect.maxY - half
        return markerBounds(center: CGPoint(x: x, y: y), in: pageBounds)
    }

    // MARK: - Text

    private struct PageGroup {
        let page: PDFPage
        let index: Int
        var rects: [CGRect]
    }

    /// Groups line rectangles by page, sorted in document order.
    ///
    /// The page comes from the line itself. Asking every line for its bounds on
    /// every page would manufacture geometry on pages it does not touch, which
    /// is exactly how a cross-page note ends up on the wrong sheet.
    private static func pageGroups(
        for selection: PDFSelection,
        in document: PDFDocument
    ) -> [PageGroup] {
        var groups: [PageGroup] = []

        for line in selection.selectionsByLine() {
            for page in line.pages {
                let index = document.index(for: page)
                guard index >= 0 else { continue }
                let rect = line.bounds(for: page)
                guard usable(rect) else { continue }

                if let existing = groups.firstIndex(where: { $0.page === page }) {
                    groups[existing].rects.append(rect)
                } else {
                    groups.append(PageGroup(page: page, index: index, rects: [rect]))
                }
            }
        }

        if groups.isEmpty, !selection.pages.isEmpty {
            for page in selection.pages {
                let index = document.index(for: page)
                guard index >= 0 else { continue }
                let rect = selection.bounds(for: page)
                guard usable(rect) else { continue }
                groups.append(PageGroup(page: page, index: index, rects: [rect]))
            }
        }

        groups.sort { $0.index < $1.index }
        return groups
    }

    private static func usable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private static func normalizedExcerpt(_ text: String?) -> String {
        (text ?? "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
