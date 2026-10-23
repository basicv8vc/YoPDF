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
    var shuaStyle: String?
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
    /// The region redrawn without the underlying PDFKit note icons.
    public let maskBounds: CGRect
    public let style: NoteStickerStyle
    /// Number of ShuaMac thoughts represented by this marker.
    public let count: Int
    /// ShuaMac shows a count badge even when a group contains one thought.
    public let showsCountBadge: Bool
    /// Bodies in group order, so the thread remains readable without ShuaMac's sidecar.
    public let threadContents: [String]
    /// Original ShuaMac icon rectangles, including portions hidden by the
    /// grouped sticker overlay. These remain valid hit targets for the group.
    public let sourceHitBounds: [CGRect]

    public var paperColor: NotePaperColor { style.palette }

    let annotation: PDFAnnotation

    init(
        annotation: PDFAnnotation,
        pageIndex: Int,
        center: CGPoint,
        bounds: CGRect,
        maskBounds: CGRect,
        style: NoteStickerStyle,
        count: Int = 1,
        showsCountBadge: Bool = false,
        threadContents: [String] = [],
        sourceHitBounds: [CGRect] = []
    ) {
        self.id = ObjectIdentifier(annotation)
        self.pageIndex = pageIndex
        self.center = center
        self.bounds = bounds
        self.maskBounds = maskBounds
        self.style = style
        self.count = count
        self.showsCountBadge = showsCountBadge
        self.threadContents = threadContents
        self.sourceHitBounds = sourceHitBounds
        self.annotation = annotation
    }

    public static func == (lhs: NoteMarker, rhs: NoteMarker) -> Bool {
        lhs.id == rhs.id
            && lhs.pageIndex == rhs.pageIndex
            && lhs.center == rhs.center
            && lhs.bounds == rhs.bounds
            && lhs.maskBounds == rhs.maskBounds
            && lhs.style == rhs.style
            && lhs.count == rhs.count
            && lhs.showsCountBadge == rhs.showsCountBadge
            && lhs.threadContents == rhs.threadContents
            && lhs.sourceHitBounds == rhs.sourceHitBounds
    }
}

/// The reversible position state of one PDF note annotation.
///
/// The PDF rectangle is kept alongside the normalized anchor: third-party PDF
/// viewers use the rectangle for the standard `/Text` note, while YoPDF uses
/// the anchor to keep its sticker from drifting when PDFKit rewrites `/Rect`.
struct NotePositionSnapshot {
    let bounds: CGRect
    let anchorX: Any?
    let anchorY: Any?
    /// Raw Shua metadata is retained so movement participates in Undo/Redo.
    let shuaMetadata: Any?
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
    /// Whether the note is rendered as an overlay sticker by YoPDF.
    public let usesStickerPresentation: Bool
    /// Number of ShuaMac thoughts grouped at this anchor, or one for a normal note.
    public let groupCount: Int
    /// The full body list for a ShuaMac group, ordered as its notes are stacked.
    public let threadContents: [String]

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
        isYoPDFNote: Bool,
        usesStickerPresentation: Bool,
        groupCount: Int,
        threadContents: [String]
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
        self.usesStickerPresentation = usesStickerPresentation
        self.groupCount = groupCount
        self.threadContents = threadContents
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
            && lhs.usesStickerPresentation == rhs.usesStickerPresentation
            && lhs.groupCount == rhs.groupCount
            && lhs.threadContents == rhs.threadContents
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

    private struct ShuaThoughtIdentity: Equatable {
        let anchorID: UUID
        let thoughtID: UUID

        var persistenceValue: String {
            "\(anchorID.uuidString):\(thoughtID.uuidString)"
        }
    }

    /// The identity and presentation fields ShuaMac embeds on thought notes.
    /// Extra anchor fields are intentionally ignored so the reader stays
    /// compatible as ShuaMac adds data to the same versioned payload.
    private struct ShuaThoughtMetadata: Decodable {
        struct Anchor: Decodable {
            struct MarkerPosition: Decodable {
                let x: Double
                let y: Double

                func point(in pageBounds: CGRect) -> CGPoint? {
                    guard x.isFinite, y.isFinite,
                          (0.0...1.0).contains(x), (0.0...1.0).contains(y),
                          pageBounds.minX.isFinite, pageBounds.minY.isFinite,
                          pageBounds.width.isFinite, pageBounds.height.isFinite,
                          pageBounds.width > 0, pageBounds.height > 0
                    else { return nil }
                    return CGPoint(
                        x: pageBounds.minX + CGFloat(x) * pageBounds.width,
                        y: pageBounds.minY + CGFloat(y) * pageBounds.height
                    )
                }
            }

            let id: UUID
            let excerpt: String?
            let isPageLevel: Bool?
            let markerPosition: MarkerPosition?
        }

        let version: Int
        let anchor: Anchor
        let thoughtID: UUID
        let thoughtOrder: Int

        var identity: ShuaThoughtIdentity {
            ShuaThoughtIdentity(anchorID: anchor.id, thoughtID: thoughtID)
        }
    }

    /// ShuaMac's unversioned Codable sticker payload. `palette` is required by
    /// ShuaMac; title and symbol are optional here so older/partial payloads
    /// can retain YoPDF's template-only fields when available.
    private struct ShuaStickerStyleMetadata: Decodable {
        let title: String?
        let symbol: String?
        let palette: String
        let motif: String?
    }

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
    /// ShuaMac stores its appearance in an optional custom PDF string.
    static let shuaStickerStyleKey = PDFAnnotationKey(rawValue: "ShuaStickerStyle")
    private static let shuaThoughtMetadataKey = PDFAnnotationKey(rawValue: "ShuaThoughtMetadata")
    /// Full `/NM` identity retained when it conflicts with embedded metadata,
    /// because PDFKit may drop `/NM` while writing the document.
    private static let shuaIdentityPersistenceKey = PDFAnnotationKey(rawValue: "/YoPDFShuaThoughtIdentity")
    /// Legacy fallback for Shua PDFs whose only group identity is `/NM`, which
    /// PDFKit may discard while serializing. Newer PDFs retain their embedded
    /// `ShuaThoughtMetadata` without this extra key.
    private static let shuaAnchorPersistenceKey = PDFAnnotationKey(rawValue: "/YoPDFShuaAnchorID")

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

    /// ShuaMac thought annotations remain standard `/Text` notes. Older files
    /// carry identity in `/NM`; newer files embed it in `ShuaThoughtMetadata`.
    /// The embedded identity takes precedence over YoPDF's legacy cache after
    /// `/NM` is lost. A conflict between Shua's two identity fields stays
    /// ungrouped rather than merging unrelated thoughts.
    public static func shuaAnchorID(of annotation: PDFAnnotation) -> UUID? {
        guard isTextAnnotation(annotation) else { return nil }

        let persistedAnchorID = (annotation.value(forAnnotationKey: shuaAnchorPersistenceKey) as? String)
            .flatMap(UUID.init(uuidString:))
        let namedIdentity = shuaThoughtIdentityFromName(of: annotation)
        let persistedIdentity = shuaThoughtIdentityFromPersistence(of: annotation)
        let metadata = shuaThoughtMetadata(of: annotation)

        if let metadata {
            if let namedIdentity {
                return namedIdentity == metadata.identity ? metadata.anchor.id : nil
            }
            if let persistedIdentity, persistedIdentity != metadata.identity { return nil }
            if let persistedAnchorID, persistedAnchorID != metadata.anchor.id { return nil }
            return metadata.anchor.id
        }

        if let namedIdentity, let persistedIdentity, namedIdentity != persistedIdentity {
            return nil
        }
        let anchorIDs = [
            persistedAnchorID,
            namedIdentity?.anchorID,
            persistedIdentity?.anchorID,
        ].compactMap { $0 }
        guard Set(anchorIDs).count <= 1 else { return nil }
        return anchorIDs.first
    }

    /// Parses ShuaMac's embedded identity without changing the annotation.
    /// Unknown versions, malformed UUIDs, missing identity fields, and
    /// negative order values are ignored so arbitrary PDF strings cannot be
    /// mistaken for a Shua group.
    private static func shuaThoughtMetadata(
        of annotation: PDFAnnotation
    ) -> ShuaThoughtMetadata? {
        guard isTextAnnotation(annotation),
              let raw = annotation.value(forAnnotationKey: shuaThoughtMetadataKey) as? String,
              let data = raw.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(ShuaThoughtMetadata.self, from: data),
              metadata.version == 1,
              metadata.thoughtOrder >= 0
        else { return nil }
        return metadata
    }

    /// Updates only Shua's shared sticker anchor inside its versioned payload.
    /// Editing the JSON object in place preserves fields owned by newer
    /// ShuaMac versions.
    private static func shuaThoughtMetadata(
        of annotation: PDFAnnotation,
        markerPosition: CGPoint,
        in pageBounds: CGRect
    ) -> String? {
        guard shuaThoughtMetadata(of: annotation) != nil,
              let raw = annotation.value(forAnnotationKey: shuaThoughtMetadataKey) as? String,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              var payload = object as? [String: Any],
              var anchor = payload["anchor"] as? [String: Any],
              pageBounds.width.isFinite, pageBounds.height.isFinite,
              pageBounds.width > 0, pageBounds.height > 0,
              markerPosition.x.isFinite, markerPosition.y.isFinite
        else { return nil }

        let x = min(max((markerPosition.x - pageBounds.minX) / pageBounds.width, 0), 1)
        let y = min(max((markerPosition.y - pageBounds.minY) / pageBounds.height, 0), 1)
        anchor["markerPosition"] = ["x": Double(x), "y": Double(y)]
        payload["anchor"] = anchor

        guard let updated = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: updated, encoding: .utf8)
    }

    /// Preserves Shua identities through PDFKit's `/NM` loss on write.
    ///
    /// Name-only annotations use a temporary anchor cache. If `/NM` conflicts
    /// with valid embedded metadata, a second temporary key preserves the full
    /// name identity so the conflict remains detectable after serialization.
    /// Temporary keys are removed from live annotations before returning.
    public static func dataRepresentationPreservingShuaGroups(
        in document: PDFDocument
    ) -> Data? {
        var previousValues: [(PDFAnnotation, PDFAnnotationKey, Any?)] = []
        defer {
            for (annotation, key, value) in previousValues {
                if let value {
                    _ = annotation.setValue(value, forAnnotationKey: key)
                } else {
                    annotation.removeValue(forAnnotationKey: key)
                }
            }
        }

        func temporarilySet(
            _ value: String?,
            for key: PDFAnnotationKey,
            on annotation: PDFAnnotation
        ) -> Bool {
            previousValues.append((annotation, key, annotation.value(forAnnotationKey: key)))
            if let value {
                return annotation.setValue(value, forAnnotationKey: key)
            } else {
                annotation.removeValue(forAnnotationKey: key)
                return true
            }
        }

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                let nameIdentity = shuaThoughtIdentityFromName(of: annotation)
                let persistedIdentity = shuaThoughtIdentityFromPersistence(of: annotation)
                let metadata = shuaThoughtMetadata(of: annotation)

                if let metadata {
                    if let nameIdentity {
                        if nameIdentity != metadata.identity {
                            if persistedIdentity != nameIdentity {
                                guard temporarilySet(
                                    nameIdentity.persistenceValue,
                                    for: shuaIdentityPersistenceKey,
                                    on: annotation
                                ) else { return nil }
                            }
                        } else if annotation.value(forAnnotationKey: shuaIdentityPersistenceKey) != nil {
                            // Current Shua fields agree; discard any stale conflict cache.
                            guard temporarilySet(nil, for: shuaIdentityPersistenceKey, on: annotation)
                            else { return nil }
                        }
                    } else if persistedIdentity == metadata.identity,
                              annotation.value(forAnnotationKey: shuaIdentityPersistenceKey) != nil {
                        guard temporarilySet(nil, for: shuaIdentityPersistenceKey, on: annotation)
                        else { return nil }
                    }
                }

                guard let nameIdentity,
                      (annotation.value(forAnnotationKey: shuaAnchorPersistenceKey) as? String)
                        .flatMap(UUID.init(uuidString:)) != nameIdentity.anchorID
                else { continue }

                guard temporarilySet(
                    nameIdentity.anchorID.uuidString,
                    for: shuaAnchorPersistenceKey,
                    on: annotation
                ) else { return nil }
            }
        }
        return document.dataRepresentation()
    }

    private static func shuaThoughtIdentityFromName(of annotation: PDFAnnotation) -> ShuaThoughtIdentity? {
        guard isTextAnnotation(annotation),
              let name = annotation.value(forAnnotationKey: .name) as? String
        else { return nil }
        let parts = name.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "shua-thought",
              let anchorID = UUID(uuidString: String(parts[1])),
              let thoughtID = UUID(uuidString: String(parts[2]))
        else { return nil }
        return ShuaThoughtIdentity(anchorID: anchorID, thoughtID: thoughtID)
    }

    private static func shuaThoughtIdentityFromPersistence(
        of annotation: PDFAnnotation
    ) -> ShuaThoughtIdentity? {
        guard isTextAnnotation(annotation),
              let raw = annotation.value(forAnnotationKey: shuaIdentityPersistenceKey) as? String
        else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let anchorID = UUID(uuidString: String(parts[0])),
              let thoughtID = UUID(uuidString: String(parts[1]))
        else { return nil }
        return ShuaThoughtIdentity(anchorID: anchorID, thoughtID: thoughtID)
    }

    private static func shuaMarkerCenter(
        from annotations: [PDFAnnotation],
        on page: PDFPage
    ) -> CGPoint? {
        // A move made in YoPDF writes the same explicit CropBox-relative anchor
        // used by YoPDF notes. It takes precedence over Shua's original marker
        // position so grouped stickers stay where the user dropped them.
        if let first = annotations.first,
           let x = normalizedAnchor(of: first, key: anchorXKey),
           let y = normalizedAnchor(of: first, key: anchorYKey) {
            let cropBox = page.bounds(for: .cropBox)
            return CGPoint(
                x: cropBox.minX + x * cropBox.width,
                y: cropBox.minY + y * cropBox.height
            )
        }

        let cropBox = page.bounds(for: .cropBox)
        for annotation in annotations {
            guard let position = shuaThoughtMetadata(of: annotation)?.anchor.markerPosition,
                  let point = position.point(in: cropBox) else { continue }
            return point
        }
        return nil
    }

    /// Returns a legacy Shua stack that contains `annotation`, when the PDF
    /// has no persisted group identity but still preserves Shua's stack layout.
    ///
    /// Some PDF round trips keep `/T = Shua` and `ShuaStickerStyle` while
    /// dropping both `/NM` and `ShuaThoughtMetadata`. In that case the only
    /// remaining group signal is the original 20pt icon rectangles stepped
    /// down by 23pt. Some PDFKit round trips rewrite those rectangles to 24pt.
    /// Requiring the exact author, matching style, matching column and a
    /// continuous run avoids merging notes merely because they are close.
    static func shuaStackMembers(
        of annotation: PDFAnnotation,
        on page: PDFPage
    ) -> [PDFAnnotation] {
        legacyShuaStackGroups(in: page.annotations).first(where: {
            $0.contains(where: { $0 === annotation })
        }) ?? [annotation]
    }

    private static func legacyShuaStackGroups(
        in annotations: [PDFAnnotation]
    ) -> [[PDFAnnotation]] {
        let tolerance: CGFloat = 0.5
        let candidates = annotations.filter { annotation in
            let bounds = annotation.bounds
            let hasSupportedIconSize = [CGFloat(20), CGFloat(24)].contains { size in
                abs(bounds.width - size) <= tolerance
                    && abs(bounds.height - size) <= tolerance
            }
            return isTextAnnotation(annotation)
                && annotation.shouldDisplay
                && annotation.userName == "Shua"
                && isShuaThought(annotation)
                && shuaAnchorID(of: annotation) == nil
                && annotation.value(forAnnotationKey: .name) == nil
                && annotation.value(forAnnotationKey: shuaThoughtMetadataKey) == nil
                && annotation.value(forAnnotationKey: shuaIdentityPersistenceKey) == nil
                && annotation.value(forAnnotationKey: shuaAnchorPersistenceKey) == nil
                && annotation.value(forAnnotationKey: shuaStickerStyleKey) != nil
                && hasSupportedIconSize
                && bounds.origin.x.isFinite
                && bounds.origin.y.isFinite
                && bounds.width.isFinite
                && bounds.height.isFinite
        }.sorted {
            if $0.bounds.midX != $1.bounds.midX {
                return $0.bounds.midX < $1.bounds.midX
            }
            return $0.bounds.midY > $1.bounds.midY
        }

        var visited = Set<ObjectIdentifier>()
        var groups: [[PDFAnnotation]] = []
        for top in candidates where !visited.contains(ObjectIdentifier(top)) {
            let topStyle = style(of: top)
            var stack = [top]
            visited.insert(ObjectIdentifier(top))
            var current = top

            while let next = candidates.first(where: { candidate in
                !visited.contains(ObjectIdentifier(candidate))
                    && style(of: candidate) == topStyle
                    && abs(candidate.bounds.midX - top.bounds.midX) <= tolerance
                    && abs(candidate.bounds.midY - (current.bounds.midY - 23)) <= tolerance
            }) {
                stack.append(next)
                visited.insert(ObjectIdentifier(next))
                current = next
            }

            if stack.count > 1 {
                groups.append(stack)
            }
        }
        return groups
    }

    public static func isShuaThought(_ annotation: PDFAnnotation) -> Bool {
        guard isTextAnnotation(annotation) else { return false }
        if shuaAnchorID(of: annotation) != nil { return true }
        if shuaThoughtMetadata(of: annotation) != nil { return true }
        if annotation.value(forAnnotationKey: shuaStickerStyleKey) != nil { return true }
        return (annotation.value(forAnnotationKey: .name) as? String)?
            .hasPrefix("shua-thought:") == true
    }

    public static func usesStickerPresentation(_ annotation: PDFAnnotation) -> Bool {
        isYoPDFNote(annotation) || isShuaThought(annotation)
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
            shuaStyle: annotation.value(forAnnotationKey: shuaStickerStyleKey) as? String,
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
        if isShuaThought(annotation),
           let data = try? JSONEncoder().encode(style),
           let shuaStyle = String(data: data, encoding: .utf8) {
            // ShuaMac decodes this unversioned Codable shape to render imported
            // thoughts. Keep it in sync when YoPDF explicitly restyles one.
            snapshot.shuaStyle = shuaStyle
        }
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
        setRawValue(snapshot.shuaStyle, forAnnotationKey: shuaStickerStyleKey, on: annotation)
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
        if let raw = annotation.value(forAnnotationKey: excerptKey) as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        guard let raw = shuaThoughtMetadata(of: annotation)?.anchor.excerpt else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func isPageLevel(_ annotation: PDFAnnotation) -> Bool {
        if let raw = annotation.value(forAnnotationKey: pageLevelKey) as? String {
            return raw == "1" || raw.caseInsensitiveCompare("true") == .orderedSame
        }
        if let isPageLevel = shuaThoughtMetadata(of: annotation)?.anchor.isPageLevel {
            return isPageLevel
        }
        return excerpt(of: annotation) == nil
    }

    /// The note's appearance, with ShuaMac and PR #6 compatibility.
    ///
    /// Shua thoughts prefer a valid `ShuaStickerStyle`, then fall back to the
    /// YoPDF style key. Other notes use `/YoPDFNoteStyle`; a note with no valid
    /// key is shown on its existing paper tint. Unknown values never rewrite
    /// the file, so merely opening a document cannot change its style.
    public static func style(of annotation: PDFAnnotation) -> NoteStickerStyle {
        let legacyPaper = paperColor(of: annotation)
        if isShuaThought(annotation) {
            // ShuaMac may edit the same PDF after YoPDF. Its current style key
            // is the shared source of truth; the YoPDF value is a fallback for
            // older files and supplies template fields absent from a partial
            // Shua payload.
            let yoPDFStyle = (annotation.value(forAnnotationKey: styleKey) as? String)
                .flatMap { NoteStickerStyle(serialized: $0, paletteFallback: legacyPaper) }
            if let raw = annotation.value(forAnnotationKey: shuaStickerStyleKey) as? String,
               let shuaStyle = decodeShuaStickerStyle(raw),
               let palette = NotePaperColor(rawValue: shuaStyle.palette),
               shuaStyle.motif.map({ NoteMotif(rawValue: $0) != nil }) ?? true {
                return NoteStickerStyle(
                    motif: shuaStyle.motif.flatMap(NoteMotif.init(rawValue:)) ?? .bunny,
                    palette: palette,
                    title: shuaStyle.title ?? yoPDFStyle?.title ?? "",
                    symbol: shuaStyle.symbol ?? yoPDFStyle?.symbol ?? NoteStickerStyle.defaultSymbol
                )
            }
            return yoPDFStyle ?? .newNote
        }
        guard let raw = annotation.value(forAnnotationKey: styleKey) as? String,
              let style = NoteStickerStyle(serialized: raw, paletteFallback: legacyPaper)
        else {
            return NoteStickerStyle(motif: .plain, palette: legacyPaper)
        }
        return style
    }

    private static func decodeShuaStickerStyle(_ raw: String) -> ShuaStickerStyleMetadata? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ShuaStickerStyleMetadata.self, from: data)
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

    static func positionSnapshot(of annotation: PDFAnnotation) -> NotePositionSnapshot {
        NotePositionSnapshot(
            bounds: annotation.bounds,
            anchorX: annotation.value(forAnnotationKey: anchorXKey),
            anchorY: annotation.value(forAnnotationKey: anchorYKey),
            shuaMetadata: annotation.value(forAnnotationKey: shuaThoughtMetadataKey)
        )
    }

    static func positionSnapshot(
        bounds: CGRect,
        anchor: CGPoint,
        on page: PDFPage,
        for annotation: PDFAnnotation
    ) -> NotePositionSnapshot? {
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 0, crop.height > 0,
              crop.width.isFinite, crop.height.isFinite,
              anchor.x.isFinite, anchor.y.isFinite
        else { return nil }

        let shuaMetadata: Any?
        if annotation.value(forAnnotationKey: shuaThoughtMetadataKey) != nil {
            guard let updated = shuaThoughtMetadata(
                of: annotation,
                markerPosition: anchor,
                in: crop
            ) else { return nil }
            shuaMetadata = updated
        } else {
            shuaMetadata = nil
        }

        let x = min(max((anchor.x - crop.minX) / crop.width, 0), 1)
        let y = min(max((anchor.y - crop.minY) / crop.height, 0), 1)
        return NotePositionSnapshot(
            bounds: bounds,
            anchorX: NSNumber(value: Double(x)),
            anchorY: NSNumber(value: Double(y)),
            shuaMetadata: shuaMetadata
        )
    }

    static func applyPositionSnapshot(
        _ snapshot: NotePositionSnapshot,
        to annotation: PDFAnnotation
    ) {
        annotation.bounds = snapshot.bounds
        if let anchorX = snapshot.anchorX {
            _ = annotation.setValue(anchorX, forAnnotationKey: anchorXKey)
        } else {
            annotation.removeValue(forAnnotationKey: anchorXKey)
        }
        if let anchorY = snapshot.anchorY {
            _ = annotation.setValue(anchorY, forAnnotationKey: anchorYKey)
        } else {
            annotation.removeValue(forAnnotationKey: anchorYKey)
        }
        if let shuaMetadata = snapshot.shuaMetadata {
            _ = annotation.setValue(shuaMetadata, forAnnotationKey: shuaThoughtMetadataKey)
        } else {
            annotation.removeValue(forAnnotationKey: shuaThoughtMetadataKey)
        }
        annotation.modificationDate = Date()
    }

    /// The sticker artwork in page space, clamped into the page.
    public static func displayBounds(
        center: CGPoint,
        in pageBounds: CGRect,
        count: Int = 1,
        showsCountBadge: Bool = false
    ) -> CGRect {
        let size = displaySize(count: count, showsCountBadge: showsCountBadge)
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let minX = pageBounds.minX + halfWidth + 2
        let maxX = pageBounds.maxX - halfWidth - 2
        let minY = pageBounds.minY + halfHeight + 2
        let maxY = pageBounds.maxY - halfHeight - 2

        let centerX = minX <= maxX ? min(max(center.x, minX), maxX) : pageBounds.midX
        let centerY = minY <= maxY ? min(max(center.y, minY), maxY) : pageBounds.midY
        return CGRect(
            x: centerX - halfWidth,
            y: centerY - halfHeight,
            width: size.width,
            height: size.height
        )
    }

    private static func displaySize(count: Int, showsCountBadge: Bool) -> CGSize {
        guard showsCountBadge else {
            return CGSize(width: markerDisplaySize, height: markerDisplaySize)
        }
        let digits = String(max(count, 1)).count
        return CGSize(width: max(38, 30 + CGFloat(digits) * 6.5), height: markerDisplaySize)
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
        pageIndex: Int,
        marker: NoteMarker? = nil
    ) -> NoteSelection? {
        guard isTextAnnotation(annotation),
              annotation.shouldDisplay,
              page.document != nil
        else { return nil }

        let owned = isYoPDFNote(annotation)
        let usesSticker = usesStickerPresentation(annotation)
        let bounds: CGRect
        let center: CGPoint
        if let marker {
            center = marker.center
            bounds = marker.bounds
        } else if usesSticker {
            center = markerCenter(of: annotation, on: page)
            bounds = displayBounds(
                center: center,
                in: page.bounds(for: .cropBox),
                showsCountBadge: isShuaThought(annotation)
            )
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
            isYoPDFNote: owned,
            usesStickerPresentation: usesSticker,
            groupCount: marker?.count ?? 1,
            threadContents: marker?.threadContents ?? [annotation.contents ?? ""]
        )
    }

    /// One visible overlay marker per YoPDF note or ShuaMac thought group.
    ///
    /// Popup annotations are skipped: they are PDFKit's companion object for a
    /// note, not a second note. Untagged third-party notes keep their native icon.
    public static func markers(in document: PDFDocument) -> [NoteMarker] {
        var markers: [NoteMarker] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let visible = page.annotations.filter {
                isTextAnnotation($0) && $0.shouldDisplay
            }
            var shuaGroups: [UUID: [PDFAnnotation]] = [:]
            var shuaGroupOrder: [UUID] = []
            for annotation in visible {
                guard let anchorID = shuaAnchorID(of: annotation) else { continue }
                if shuaGroups[anchorID] == nil {
                    shuaGroupOrder.append(anchorID)
                }
                shuaGroups[anchorID, default: []].append(annotation)
            }

            for annotation in visible
                where isYoPDFNote(annotation)
                    && !isShuaThought(annotation)
                    && shuaAnchorID(of: annotation) == nil
            {
                let center = markerCenter(of: annotation, on: page)
                let bounds = displayBounds(center: center, in: page.bounds(for: .cropBox))
                markers.append(NoteMarker(
                    annotation: annotation,
                    pageIndex: pageIndex,
                    center: center,
                    bounds: bounds,
                    maskBounds: bounds,
                    style: style(of: annotation),
                    threadContents: [annotation.contents ?? ""]
                ))
            }

            let legacyStacks = legacyShuaStackGroups(in: visible)
            let legacyStackMembers = Set(
                legacyStacks.flatMap { $0 }.map(ObjectIdentifier.init)
            )
            for annotation in visible
                where isShuaThought(annotation)
                    && shuaAnchorID(of: annotation) == nil
                    && !legacyStackMembers.contains(ObjectIdentifier(annotation))
            {
                let center = markerCenter(of: annotation, on: page)
                let bounds = displayBounds(
                    center: center,
                    in: page.bounds(for: .cropBox),
                    showsCountBadge: true
                )
                markers.append(NoteMarker(
                    annotation: annotation,
                    pageIndex: pageIndex,
                    center: center,
                    bounds: bounds,
                    maskBounds: annotation.bounds
                        .union(bounds)
                        .insetBy(dx: -2, dy: -2)
                        .intersection(page.bounds(for: .cropBox)),
                    style: style(of: annotation),
                    showsCountBadge: true,
                    threadContents: [annotation.contents ?? ""],
                    sourceHitBounds: [annotation.bounds]
                ))
            }

            for notes in legacyStacks {
                guard let first = notes.first else { continue }
                let proposedCenter = CGPoint(
                    x: first.bounds.midX,
                    y: first.bounds.midY + 10
                )
                let center = shuaMarkerCenter(from: notes, on: page)
                    ?? (proposedCenter.x.isFinite && proposedCenter.y.isFinite
                        ? proposedCenter
                        : markerCenter(of: first, on: page))
                let bounds = displayBounds(
                    center: center,
                    in: page.bounds(for: .cropBox),
                    count: notes.count,
                    showsCountBadge: true
                )
                let notesBounds = notes.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
                let maskBounds = notesBounds
                    .union(bounds)
                    .insetBy(dx: -2, dy: -2)
                    .intersection(page.bounds(for: .cropBox))
                markers.append(NoteMarker(
                    annotation: first,
                    pageIndex: pageIndex,
                    center: center,
                    bounds: bounds,
                    maskBounds: maskBounds,
                    style: style(of: first),
                    count: notes.count,
                    showsCountBadge: true,
                    threadContents: notes.map { $0.contents ?? "" },
                    sourceHitBounds: notes.map(\.bounds)
                ))
            }

            let annotationOrder = Dictionary(
                uniqueKeysWithValues: page.annotations.enumerated().map {
                    (ObjectIdentifier($0.element), $0.offset)
                }
            )
            for anchorID in shuaGroupOrder {
                guard let group = shuaGroups[anchorID] else { continue }
                let hasCompleteThoughtOrder = group.allSatisfy {
                    shuaThoughtMetadata(of: $0) != nil
                }
                let notes = group.sorted {
                    if hasCompleteThoughtOrder {
                        let leftThoughtOrder = shuaThoughtMetadata(of: $0)?.thoughtOrder ?? 0
                        let rightThoughtOrder = shuaThoughtMetadata(of: $1)?.thoughtOrder ?? 0
                        if leftThoughtOrder != rightThoughtOrder {
                            return leftThoughtOrder < rightThoughtOrder
                        }
                    }
                    if $0.bounds.midY != $1.bounds.midY {
                        return $0.bounds.midY > $1.bounds.midY
                    }
                    let leftOrder = annotationOrder[ObjectIdentifier($0)] ?? 0
                    let rightOrder = annotationOrder[ObjectIdentifier($1)] ?? 0
                    return leftOrder < rightOrder
                }
                guard let first = notes.first else { continue }
                // ShuaMac stores each group's thought annotations as 20pt icons
                // stepped down by 23pt. The first icon's centre is 10pt below
                // the shared sticker anchor. PR #1007 also persists the exact
                // CropBox-relative anchor; prefer it after PDFKit rewrites Rect.
                let proposedCenter = CGPoint(x: first.bounds.midX, y: first.bounds.midY + 10)
                let center = shuaMarkerCenter(from: notes, on: page)
                    ?? (proposedCenter.x.isFinite && proposedCenter.y.isFinite
                        ? proposedCenter
                        : markerCenter(of: first, on: page))
                let bounds = displayBounds(
                    center: center,
                    in: page.bounds(for: .cropBox),
                    count: notes.count,
                    showsCountBadge: true
                )
                let notesBounds = notes.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
                let maskBounds = notesBounds
                    .union(bounds)
                    .insetBy(dx: -2, dy: -2)
                    .intersection(page.bounds(for: .cropBox))
                markers.append(NoteMarker(
                    annotation: first,
                    pageIndex: pageIndex,
                    center: center,
                    bounds: bounds,
                    maskBounds: maskBounds,
                    style: style(of: first),
                    count: notes.count,
                    showsCountBadge: true,
                    threadContents: notes.map { $0.contents ?? "" },
                    sourceHitBounds: notes.map(\.bounds)
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
        guard usesStickerPresentation(annotation) else { return annotation.bounds }
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
