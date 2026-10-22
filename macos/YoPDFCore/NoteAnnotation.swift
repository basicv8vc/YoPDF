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

/// The exact appearance-related state of one note.
///
/// A style edit has to be reversible even for a third-party note that had no
/// YoPDF keys at all. A plain `NoteStickerStyle` value is not enough: Undo must
/// also be able to remove the keys it introduced and restore the original `/C`
/// colour, or an undone adoption would still be recognised as a YoPDF note.
struct NoteStyleSnapshot {
    var identity: String?
    var paper: String?
    var style: String?
    var color: NSColor
}

/// What the page overlay needs to draw one marker.
///
/// `center` is the persisted anchor in page space; `bounds` is the fixed-size
/// card the overlay draws around it. The annotation's own `/Rect` is not used
/// once an anchor exists, because PDFKit may rewrite it on the first save.
public struct NoteMarker: Identifiable, Equatable {
    public let id: ObjectIdentifier
    public let pageIndex: Int
    /// The sticker centre in page space.
    public let center: CGPoint
    /// The sticker card in page space, clamped into the CropBox.
    public let bounds: CGRect
    public let style: NoteStickerStyle

    public var paperColor: NotePaperColor { style.palette }

    init(
        annotation: PDFAnnotation,
        pageIndex: Int,
        center: CGPoint,
        bounds: CGRect,
        style: NoteStickerStyle
    ) {
        self.id = ObjectIdentifier(annotation)
        self.pageIndex = pageIndex
        self.center = center
        self.bounds = bounds
        self.style = style
    }
}

/// The note the user clicked, in the terms the composer needs.
///
/// The `PDFAnnotation` stays internal so a SwiftUI view cannot mutate PDFKit
/// behind the model's back; every edit goes through `PDFDocumentModel`.
public struct NoteSelection: Identifiable, Equatable {
    public let pageIndex: Int
    /// The sticker card in page space, used to anchor the popover.
    public let bounds: CGRect
    /// The sticker centre in page space.
    public let center: CGPoint
    public let contents: String
    public let style: NoteStickerStyle
    public let excerpt: String?
    public let isPageLevel: Bool
    /// Whether YoPDF owns this note's sticker presentation.
    ///
    /// `false` for an untouched third-party `/Text` note: it is still readable
    /// and editable, but keeps PDFKit's native icon and native hit target.
    public let isYoPDFNote: Bool

    public var paperColor: NotePaperColor { style.palette }

    let annotation: PDFAnnotation

    public var id: ObjectIdentifier { ObjectIdentifier(annotation) }

    /// 1-based page label for the composer header.
    public var pageLabel: String { "Page \(pageIndex + 1)" }

    init(
        annotation: PDFAnnotation,
        pageIndex: Int,
        bounds: CGRect,
        center: CGPoint,
        contents: String,
        style: NoteStickerStyle,
        excerpt: String?,
        isPageLevel: Bool,
        isYoPDFNote: Bool
    ) {
        self.annotation = annotation
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.center = center
        self.contents = contents
        self.style = style
        self.excerpt = excerpt
        self.isPageLevel = isPageLevel
        self.isYoPDFNote = isYoPDFNote
    }

    public static func == (lhs: NoteSelection, rhs: NoteSelection) -> Bool {
        lhs.annotation === rhs.annotation
            && lhs.pageIndex == rhs.pageIndex
            && lhs.bounds == rhs.bounds
            && lhs.center == rhs.center
            && lhs.contents == rhs.contents
            && lhs.style == rhs.style
            && lhs.excerpt == rhs.excerpt
            && lhs.isPageLevel == rhs.isPageLevel
            && lhs.isYoPDFNote == rhs.isYoPDFNote
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

    /// The minimum `/Text` rectangle PDFKit keeps after serialization.
    public static let markerSize: CGFloat = 24
    /// The visible sticker artwork, matching ShuaMac's 32pt marker face.
    ///
    /// It is larger than the 24pt `/Rect` because the artwork is the visible
    /// hit target; the annotation rectangle is PDFKit's storage detail.
    public static let markerDisplaySize: CGFloat = 32
    /// The custom keys are deliberately namespaced and optional.
    ///
    /// PDF annotation keys are written with their leading slash, exactly like
    /// `/Contents`; `PDFAnnotationKey` compares the raw string, so a key without
    /// it would be written but never read back.
    static let paperColorKey = PDFAnnotationKey(rawValue: "/YoPDFNotePaper")
    static let excerptKey = PDFAnnotationKey(rawValue: "/YoPDFNoteExcerpt")
    static let pageLevelKey = PDFAnnotationKey(rawValue: "/YoPDFNotePageLevel")
    /// Versioned sticker style. `/Contents` remains the only body storage.
    static let styleKey = PDFAnnotationKey(rawValue: "/YoPDFNoteStyle")
    /// Provenance marker: this annotation's presentation is owned by YoPDF.
    ///
    /// `/NM` is not usable because PDFKit drops it on serialization, and
    /// `userName` is author text that any application can set. A namespaced
    /// custom key survives the round trip and is the only reliable way to tell
    /// our notes from an untouched third-party `/Text` note.
    static let identityKey = PDFAnnotationKey(rawValue: "/YoPDFNoteIdentity")
    static let identityValue = "yopdf-note-1"
    /// Anchor normalized to the page's CropBox, in 0...1.
    static let anchorXKey = PDFAnnotationKey(rawValue: "/YoPDFNoteAnchorX")
    static let anchorYKey = PDFAnnotationKey(rawValue: "/YoPDFNoteAnchorY")

    public static func isTextAnnotation(_ annotation: PDFAnnotation) -> Bool {
        guard let type = annotation.type else { return false }
        return type == "Text" || type == "/Text"
    }

    /// Whether this annotation's sticker presentation belongs to YoPDF.
    ///
    /// Recognition is deliberately narrow and never uses `/C`, the note body,
    /// `userName`, or `/NM`:
    ///
    /// 1. `/YoPDFNoteIdentity` is present (notes created by this build); or
    /// 2. a legacy PR #6 key is present (`/YoPDFNotePaper` or
    ///    `/YoPDFNotePageLevel`), or a style key exists from a build before the
    ///    identity marker (`/YoPDFNoteStyle`).
    ///
    /// A third-party `/Text` note has none of these, so it keeps PDFKit's native
    /// icon and native hit target. Opening a PR #6 file does not add the
    /// identity key; only an explicit edit can write new metadata.
    public static func isYoPDFNote(_ annotation: PDFAnnotation) -> Bool {
        if let identity = annotation.value(forAnnotationKey: identityKey) as? String,
           !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        // PR #6 notes always carry the paper and page-level keys. The style key
        // is also ours, so a note whose identity key was stripped by another
        // editor is still recognised rather than losing its overlay silently.
        for key in [paperColorKey, pageLevelKey, styleKey] {
            guard let value = annotation.value(forAnnotationKey: key) else { continue }
            if let text = value as? String {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            } else {
                return true
            }
        }
        return false
    }

    /// The current appearance state, including which YoPDF keys actually exist.
    ///
    /// Captured before a style edit so Undo can remove keys the edit introduced
    /// rather than substituting equivalent values. This is what makes an undone
    /// adoption of a third-party note return to its native presentation.
    static func styleSnapshot(of annotation: PDFAnnotation) -> NoteStyleSnapshot {
        NoteStyleSnapshot(
            identity: annotation.value(forAnnotationKey: identityKey) as? String,
            paper: annotation.value(forAnnotationKey: paperColorKey) as? String,
            style: annotation.value(forAnnotationKey: styleKey) as? String,
            color: annotation.color
        )
    }

    /// The state after applying `style` and claiming ownership of the note.
    static func styledSnapshot(
        for style: NoteStickerStyle,
        on annotation: PDFAnnotation
    ) -> NoteStyleSnapshot {
        var snapshot = styleSnapshot(of: annotation)
        snapshot.identity = identityValue
        snapshot.paper = style.palette.rawValue
        snapshot.style = style.serialized
        snapshot.color = style.palette.color
        return snapshot
    }

    /// Restores an exact snapshot, including removing keys that were absent.
    static func applyStyleSnapshot(
        _ snapshot: NoteStyleSnapshot,
        to annotation: PDFAnnotation
    ) {
        setRawValue(snapshot.identity, forAnnotationKey: identityKey, on: annotation)
        setRawValue(snapshot.paper, forAnnotationKey: paperColorKey, on: annotation)
        setRawValue(snapshot.style, forAnnotationKey: styleKey, on: annotation)
        annotation.color = snapshot.color
        annotation.modificationDate = Date()
    }

    private static func setRawValue(
        _ value: String?,
        forAnnotationKey key: PDFAnnotationKey,
        on annotation: PDFAnnotation
    ) {
        if let value {
            _ = annotation.setValue(value, forAnnotationKey: key)
        } else {
            annotation.removeValue(forAnnotationKey: key)
        }
    }

    /// Writes the full appearance in one place and claims ownership.
    ///
    /// `/YoPDFNoteIdentity`, `/YoPDFNotePaper` and `/C` are kept in sync so
    /// older YoPDF builds and standard readers still show the right tint if
    /// they ignore the style key. Every note created here goes through this
    /// method; it is also why an explicitly restyled third-party note becomes a
    /// YoPDF note.
    public static func setStyle(_ style: NoteStickerStyle, on annotation: PDFAnnotation) {
        applyStyleSnapshot(styledSnapshot(for: style, on: annotation), to: annotation)
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

    /// The note's appearance, with PR #6 compatibility.
    ///
    /// A note written before this build has no `/YoPDFNoteStyle`; it is shown as
    /// Simple Paper on its existing paper tint. A value that is not a JSON
    /// object is treated the same way. An unknown motif becomes `plain` without
    /// rewriting the file, so merely opening a document cannot change it.
    public static func style(of annotation: PDFAnnotation) -> NoteStickerStyle {
        let legacyPaper = paperColor(of: annotation)
        guard let raw = annotation.value(forAnnotationKey: styleKey) as? String,
              let style = NoteStickerStyle(serialized: raw, paletteFallback: legacyPaper)
        else {
            return NoteStickerStyle(motif: .plain, palette: legacyPaper)
        }
        return style
    }

    private static func normalizedAnchor(
        of annotation: PDFAnnotation,
        key: PDFAnnotationKey
    ) -> CGFloat? {
        guard let number = annotation.value(forAnnotationKey: key) as? NSNumber else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        return CGFloat(min(max(value, 0), 1))
    }

    /// The sticker centre in page space.
    ///
    /// The normalized anchor wins when present. Otherwise the annotation's
    /// current `/Rect` centre is used, which is the only geometry a PR #6 or
    /// third-party note has. That fallback may move by a point after PDFKit
    /// rewrites `/Rect` on the first save; a note created by this build has an
    /// anchor and does not drift at all.
    public static func markerCenter(
        of annotation: PDFAnnotation,
        on page: PDFPage
    ) -> CGPoint {
        let crop = page.bounds(for: .cropBox)
        if crop.width > 0, crop.height > 0,
           let x = normalizedAnchor(of: annotation, key: anchorXKey),
           let y = normalizedAnchor(of: annotation, key: anchorYKey) {
            return CGPoint(
                x: crop.minX + x * crop.width,
                y: crop.minY + y * crop.height
            )
        }

        let rect = annotation.bounds
        if rect.width.isFinite, rect.height.isFinite,
           rect.origin.x.isFinite, rect.origin.y.isFinite,
           rect.width > 1, rect.height > 1 {
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        return CGPoint(x: crop.midX, y: crop.midY)
    }

    /// Persists the marker centre as a CropBox-relative point.
    ///
    /// Called only when a note is created (and later, by the dragging PR). An
    /// existing note is never backfilled: doing so during load or save would
    /// freeze a position the user never chose.
    public static func setAnchor(
        _ point: CGPoint,
        on annotation: PDFAnnotation,
        page: PDFPage
    ) {
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 0, crop.height > 0,
              point.x.isFinite, point.y.isFinite
        else { return }

        let x = min(max((point.x - crop.minX) / crop.width, 0), 1)
        let y = min(max((point.y - crop.minY) / crop.height, 0), 1)
        _ = annotation.setValue(NSNumber(value: Double(x)), forAnnotationKey: anchorXKey)
        _ = annotation.setValue(NSNumber(value: Double(y)), forAnnotationKey: anchorYKey)
    }

    /// The sticker artwork in page space, clamped into the page.
    public static func displayBounds(center: CGPoint, in pageBounds: CGRect) -> CGRect {
        let half = markerDisplaySize / 2
        let minX = pageBounds.minX + half + 2
        let maxX = pageBounds.maxX - half - 2
        let minY = pageBounds.minY + half + 2
        let maxY = pageBounds.maxY - half - 2

        let centerX = minX <= maxX ? min(max(center.x, minX), maxX) : pageBounds.midX
        let centerY = minY <= maxY ? min(max(center.y, minY), maxY) : pageBounds.midY
        return CGRect(
            x: centerX - half,
            y: centerY - half,
            width: markerDisplaySize,
            height: markerDisplaySize
        )
    }

    /// The marker artwork in page space.
    ///
    /// A malformed third-party note with an empty rectangle still gets a
    /// visible marker at the page centre rather than disappearing entirely.
    public static func resolvedBounds(
        for annotation: PDFAnnotation,
        on page: PDFPage
    ) -> CGRect {
        displayBounds(
            center: markerCenter(of: annotation, on: page),
            in: page.bounds(for: .cropBox)
        )
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

        let owned = isYoPDFNote(annotation)
        let bounds: CGRect
        let center: CGPoint
        if owned {
            center = markerCenter(of: annotation, on: page)
            bounds = displayBounds(center: center, in: page.bounds(for: .cropBox))
        } else {
            // No overlay is drawn for a third-party note, so the popover and the
            // hit target use the native annotation rectangle, not an invented card.
            bounds = annotation.bounds
            center = CGPoint(x: bounds.midX, y: bounds.midY)
        }

        return NoteSelection(
            annotation: annotation,
            pageIndex: pageIndex,
            bounds: bounds,
            center: center,
            contents: annotation.contents ?? "",
            style: style(of: annotation),
            excerpt: excerpt(of: annotation),
            isPageLevel: isPageLevel(annotation),
            isYoPDFNote: owned
        )
    }

    /// Every visible standard `/Text` annotation whose presentation YoPDF owns.
    ///
    /// Popup annotations are skipped: they are PDFKit's companion object for a
    /// note, not a second note. A third-party `/Text` note is deliberately not
    /// included: drawing a sticker card over it would silently replace another
    /// application's note icon.
    public static func markers(in document: PDFDocument) -> [NoteMarker] {
        var markers: [NoteMarker] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where isTextAnnotation(annotation) {
                guard annotation.shouldDisplay, isYoPDFNote(annotation) else { continue }
                let center = markerCenter(of: annotation, on: page)
                markers.append(NoteMarker(
                    annotation: annotation,
                    pageIndex: pageIndex,
                    center: center,
                    bounds: displayBounds(
                        center: center,
                        in: page.bounds(for: .cropBox)
                    ),
                    style: style(of: annotation)
                ))
            }
        }
        return markers
    }

    /// The click target for one note.
    ///
    /// A YoPDF note uses its drawn sticker face, inset by 3pt like ShuaMac's
    /// marker hit target. An untouched third-party note uses its native
    /// annotation bounds; it must not gain an invisible sticker-sized target
    /// just because YoPDF knows how to attach stickers.
    public static func hitRect(for annotation: PDFAnnotation, on page: PDFPage) -> CGRect {
        guard isYoPDFNote(annotation) else { return annotation.bounds }
        return resolvedBounds(for: annotation, on: page)
            .insetBy(dx: -3, dy: -3)
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

    /// Creates the standard `/Text` annotation for a draft.
    ///
    /// The `/Rect` is already at PDFKit's 24×24 minimum, and the real position
    /// is written as a CropBox-relative anchor in the same step. A page is
    /// required because the anchor is normalized against its CropBox.
    public static func annotation(
        for draft: NoteDraft,
        contents: String,
        style: NoteStickerStyle,
        on page: PDFPage
    ) -> PDFAnnotation? {
        let text = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, page.document != nil else { return nil }

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
        setStyle(style, on: annotation)
        setAnchor(
            CGPoint(x: draft.bounds.midX, y: draft.bounds.midY),
            on: annotation,
            page: page
        )
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
