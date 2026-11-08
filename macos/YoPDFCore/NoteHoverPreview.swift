import Foundation

/// What a hover card shows for one note sticker.
///
/// A sticker can stand for a whole thread of notes, so the preview is a list of
/// entries in thread order rather than one body. The value carries no
/// `PDFAnnotation` and no color: the reader must be able to draw the card
/// without touching the document, and nothing here can be edited.
public struct NoteHoverPreview: Equatable, Sendable {

    public struct Entry: Equatable, Sendable {
        /// The body exactly as stored. Whitespace is preserved because the note
        /// belongs to the user; the card decides how to present a blank one.
        public let contents: String
        public let palette: NotePaperColor
        public let motif: NoteMotif

        public init(contents: String, palette: NotePaperColor, motif: NoteMotif) {
            self.contents = contents
            self.palette = palette
            self.motif = motif
        }

        /// True when the note holds no readable characters at all.
        public var isBlank: Bool {
            contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The sticker's own name, or `untitled`. This is the same fallback
    /// `NoteStickerHeading` uses, so the card and the expanded editor never
    /// disagree about what a note is called.
    public let title: String
    /// The sticker's paper, used to tint the card so it reads as part of the
    /// same note.
    public let palette: NotePaperColor
    /// The sticker's motif, drawn in the card header.
    public let motif: NoteMotif
    /// Every note behind the sticker, in the order the thread stores them.
    public let entries: [Entry]

    public static let untitled = "Note"

    public init(title: String, palette: NotePaperColor, motif: NoteMotif, entries: [Entry]) {
        self.title = title
        self.palette = palette
        self.motif = motif
        self.entries = entries
    }

    /// Builds the preview for a sticker.
    ///
    /// `threadEntries` already carries each note's own body and style, so a
    /// thread keeps its per-note paper colours. The body list is only a
    /// fallback for a marker built without entries.
    public init(marker: NoteMarker) {
        let style = marker.style
        var entries = marker.threadEntries.map { entry in
            Entry(
                contents: entry.contents,
                palette: entry.style.palette,
                motif: entry.style.motif
            )
        }
        if entries.isEmpty {
            entries = marker.threadContents.map {
                Entry(contents: $0, palette: style.palette, motif: style.motif)
            }
        }
        if entries.isEmpty {
            // A marker always owns at least one annotation. Keeping an empty
            // body here rather than dropping the sticker means the card can
            // still say the note exists.
            entries = [Entry(contents: "", palette: style.palette, motif: style.motif)]
        }

        self.init(
            title: style.displayTitle.isEmpty ? Self.untitled : style.displayTitle,
            palette: style.palette,
            motif: style.motif,
            entries: entries
        )
    }

    /// The label for a thread, or `nil` for a single note. A single note needs
    /// no count: "1 note" would only be noise next to a lone sticker.
    public var countTitle: String? {
        guard entries.count > 1 else { return nil }
        return "\(entries.count) notes"
    }
}
