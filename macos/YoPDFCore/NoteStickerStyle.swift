import Foundation

/// One illustrated sticker motif.
///
/// The raw values are the persistent identity written into the PDF. They are
/// deliberately the same strings ShuaMac uses, so a future reader can recognise
/// a Shua note without a second mapping table. The collection is a UI grouping
/// only; moving a motif between collections must never change its raw value.
public enum NoteMotif: String, CaseIterable, Hashable, Sendable {
    // Cream Journal
    case bunny
    case cat
    case flower
    case star
    // Purrs & Wags
    case tuxedoCat
    case sleepyCat
    case shiba
    case puppy
    // Cozy Animals
    case hamster
    case panda
    case redPanda
    case otter
    // Playful Art
    case heart
    case cloud
    case cherry
    case bow
    // Vintage Collage
    case roseStamp
    case botanical
    case letter
    case washi
    // Simple Paper
    case plain

    /// The Asset Catalog name, or `nil` for Simple Paper (no illustration).
    public var assetName: String? {
        switch self {
        case .bunny: return "PDFStickerBunny"
        case .cat: return "PDFStickerCat"
        case .flower: return "PDFStickerFlower"
        case .star: return "PDFStickerStar"
        case .tuxedoCat: return "PDFStickerTuxedoCat"
        case .sleepyCat: return "PDFStickerSleepyCat"
        case .shiba: return "PDFStickerShiba"
        case .puppy: return "PDFStickerPuppy"
        case .hamster: return "PDFStickerHamster"
        case .panda: return "PDFStickerPanda"
        case .redPanda: return "PDFStickerRedPanda"
        case .otter: return "PDFStickerOtter"
        case .heart: return "PDFStickerHeart"
        case .cloud: return "PDFStickerCloud"
        case .cherry: return "PDFStickerCherry"
        case .bow: return "PDFStickerBow"
        case .roseStamp: return "PDFStickerRoseStamp"
        case .botanical: return "PDFStickerBotanical"
        case .letter: return "PDFStickerLetter"
        case .washi: return "PDFStickerWashi"
        case .plain: return nil
        }
    }

    /// Short English labels. The app has no localization table yet, so these
    /// stay literals for now.
    public var title: String {
        switch self {
        case .bunny: return "Little Bunny"
        case .cat: return "Little Cat"
        case .flower: return "Daisy"
        case .star: return "Little Star"
        case .tuxedoCat: return "Tuxedo Kitten"
        case .sleepyCat: return "Sleepy Kitten"
        case .shiba: return "Little Shiba"
        case .puppy: return "Floppy Puppy"
        case .hamster: return "Little Hamster"
        case .panda: return "Baby Panda"
        case .redPanda: return "Red Panda"
        case .otter: return "Little Otter"
        case .heart: return "Sweet Heart"
        case .cloud: return "Sleepy Cloud"
        case .cherry: return "Cherries"
        case .bow: return "Ribbon Bow"
        case .roseStamp: return "Rose Stamp"
        case .botanical: return "Botanical Label"
        case .letter: return "Little Letter"
        case .washi: return "Floral Washi"
        case .plain: return "Simple Paper"
        }
    }

    public var collection: NoteStickerCollection {
        switch self {
        case .bunny, .cat, .flower, .star:
            return .cream
        case .tuxedoCat, .sleepyCat, .shiba, .puppy:
            return .pets
        case .hamster, .panda, .redPanda, .otter:
            return .animals
        case .heart, .cloud, .cherry, .bow:
            return .doodle
        case .roseStamp, .botanical, .letter, .washi:
            return .vintage
        case .plain:
            return .minimal
        }
    }
}

/// The UI grouping of motifs. Not persisted; a motif ID is the identity.
public enum NoteStickerCollection: String, CaseIterable, Hashable, Sendable {
    case cream
    case pets
    case animals
    case doodle
    case vintage
    case minimal

    public var title: String {
        switch self {
        case .cream: return "Cream Journal"
        case .pets: return "Purrs & Wags"
        case .animals: return "Cozy Animals"
        case .doodle: return "Playful Art"
        case .vintage: return "Vintage Collage"
        case .minimal: return "Simple Paper"
        }
    }

    public var motifs: [NoteMotif] {
        NoteMotif.allCases.filter { $0.collection == self }
    }
}

/// The persistent appearance of a note: one motif and one paper palette.
///
/// This is a value, not a reference to a template. A saved note carries its own
/// snapshot, so editing or deleting a template later cannot change it. The
/// serialized form is a small, versioned JSON object stored in the optional
/// `/YoPDFNoteStyle` annotation key; losing it costs the appearance, never the
/// body, because the body remains in the standard `/Contents` entry.
///
/// Decoding is deliberately forgiving: an unknown motif becomes `plain`, an
/// unknown or missing palette falls back to the caller's legacy paper, and a
/// document that contains arbitrary bytes in the key still opens.
public struct NoteStickerStyle: Hashable, Sendable {

    /// Bumped only when the meaning of an existing field changes or a field is
    /// removed. Readers ignore versions they do not know and keep the fields
    /// they do understand.
    public static let currentVersion = 1

    public var motif: NoteMotif
    public var palette: NotePaperColor

    public init(motif: NoteMotif = .plain, palette: NotePaperColor = .honey) {
        self.motif = motif
        self.palette = palette
    }

    /// The default for a new note and the fallback for a note with no style key.
    public static let plain = NoteStickerStyle(motif: .plain, palette: .honey)

    /// The value written to `/YoPDFNoteStyle`.
    ///
    /// Fixed key order and ASCII-only raw values keep the value readable in a
    /// PDF inspector and deterministic for tests. It is a JSON object rather
    /// than a PDF dictionary because a string custom key round-trips through
    /// PDFKit unchanged (verified on this platform).
    public var serialized: String {
        "{\"v\":\(Self.currentVersion),\"motif\":\"\(motif.rawValue)\","
            + "\"palette\":\"\(palette.rawValue)\"}"
    }

    /// Decodes `/YoPDFNoteStyle`.
    ///
    /// Returns `nil` only when the value is not a JSON object at all. An object
    /// with an unknown motif ID resolves to `plain`; an unknown palette uses
    /// `paletteFallback`, which is normally the note's `/YoPDFNotePaper` or
    /// `/C` colour. That separation is what keeps a PR #6 note looking the same
    /// when it is read by this build.
    public init?(serialized: String, paletteFallback: NotePaperColor = .honey) {
        guard let data = serialized.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any]
        else { return nil }

        let motif = (fields["motif"] as? String)
            .flatMap(NoteMotif.init(rawValue:)) ?? .plain
        let palette = (fields["palette"] as? String)
            .flatMap(NotePaperColor.init(rawValue:)) ?? paletteFallback
        self.init(motif: motif, palette: palette)
    }
}
