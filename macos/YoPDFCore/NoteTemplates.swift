import Combine
import Foundation

/// A reusable note outline plus its appearance.
///
/// A template is only a seed. The note that applies it stores its own style
/// snapshot, so editing or deleting a template later cannot change an existing
/// annotation.
public struct NoteTemplate: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var style: NoteStickerStyle
    public var body: String

    public init(id: String, style: NoteStickerStyle, body: String) {
        self.id = id
        self.style = style
        self.body = body
    }

    /// A template changes the appearance, but only seeds an untouched editor.
    /// Matching is by body alone: changing a palette or motif must not make a
    /// template outline look like user-written text.
    public func applying(to text: String, previousSeed: String?) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == previousSeed
            ? body
            : text
    }

    /// The twelve built-in templates from ShuaMac, with the same identities,
    /// symbols, palettes, motifs, titles, and outlines.
    public static func builtIns() -> [NoteTemplate] {
        let definitions: [(String, String, String, NotePaperColor, String)] = [
            ("blank", "Blank", "note.text", .honey, ""),
            ("insight", "Insight", "lightbulb", .honey, "Key insight:\n\nWhy it matters:\n"),
            ("question", "Question", "questionmark.bubble", .sky, "My question:\n\nWhat would answer it:\n"),
            ("summary", "Summary", "text.alignleft", .sand, "In my own words:\n\nTakeaway:\n"),
            ("method", "Method", "slider.horizontal.3", .mint, "Approach:\n\nAssumptions:\n\nWhen to use it:\n"),
            ("evidence", "Evidence", "chart.bar", .sky, "Claim:\n\nSupporting evidence:\n\nHow strong is it?\n"),
            ("limitation", "Limitation", "exclamationmark.triangle", .rose, "Limitation:\n\nImpact on the results:\n"),
            ("experiment", "To Verify", "flask", .lavender, "Hypothesis:\n\nExperiment to try:\n\nExpected result:\n"),
            ("connection", "Connection", "link", .mint, "Related work or idea:\n\nConnection to this passage:\n"),
            ("action", "Next Step", "checklist", .honey, "Next step:\n\nDone when:\n"),
            ("quote", "Quote", "quote.opening", .sand, "Why I saved this passage:\n\nWhere I could use it:\n"),
            ("review", "Review", "text.badge.checkmark", .lavender, "Strength:\n\nConcern:\n\nRecommendation:\n"),
        ]

        return definitions.map { id, title, symbol, palette, body in
            let motif: NoteMotif
            switch id {
            case "insight": motif = .star
            case "review": motif = .cat
            case "connection": motif = .flower
            case "question": motif = .cloud
            case "limitation": motif = .heart
            case "experiment": motif = .cherry
            case "action": motif = .bow
            case "method": motif = .botanical
            case "evidence": motif = .roseStamp
            case "summary": motif = .letter
            case "quote": motif = .washi
            default: motif = .bunny
            }
            return NoteTemplate(
                id: "builtin.\(id)",
                style: NoteStickerStyle(
                    motif: motif,
                    palette: palette,
                    title: title,
                    symbol: symbol
                ),
                body: body
            )
        }
    }
}

/// The editor's template seed, owned outside the temporary appearance popover.
///
/// The seed remembers which outline came from a template even after the user
/// changes the motif or palette. That is what lets the next template replace an
/// untouched outline instead of treating it as user-written text.
public struct NoteTemplateSelection: Equatable, Sendable {
    public private(set) var seed: String?

    public init(seed: String? = nil) {
        self.seed = seed
    }

    public mutating func restoreIfNeeded(text: String, templates: [NoteTemplate]) {
        guard seed == nil, !text.isEmpty else { return }
        seed = templates.first { $0.body == text }?.body
    }

    public mutating func apply(_ template: NoteTemplate, to text: String) -> String {
        let result = template.applying(to: text, previousSeed: seed)
        seed = template.body
        return result
    }

    public mutating func reset() {
        seed = nil
    }
}

/// User templates are preferences; notes are documents.
///
/// An unreadable library is kept exactly as stored and writes are refused. A
/// corrupt preferences blob must never silently erase templates the user made.
@MainActor
public final class NoteTemplateStore: ObservableObject {
    public static let shared = NoteTemplateStore()
    public static let storageKey = "YoPDFNoteTemplates.v1"

    @Published public private(set) var templates: [NoteTemplate] = []
    @Published public private(set) var loadFailed = false

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            templates = try JSONDecoder().decode([NoteTemplate].self, from: data)
        } catch {
            // Keep the original bytes rather than replacing an unreadable
            // library with an empty one on the next save.
            loadFailed = true
        }
    }

    @discardableResult
    public func save(
        id: String? = nil,
        style: NoteStickerStyle,
        body: String
    ) throws -> NoteTemplate {
        guard !loadFailed else { throw LibraryError.unreadable }
        let title = style.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LibraryError.missingName }

        var style = style
        style.title = title
        let template = NoteTemplate(
            id: id ?? UUID().uuidString,
            style: style,
            body: body
        )

        var updated = templates
        if let index = updated.firstIndex(where: { $0.id == template.id }) {
            updated[index] = template
        } else {
            updated.append(template)
        }
        try persist(updated)
        return template
    }

    public func delete(id: String) throws {
        guard !loadFailed else { throw LibraryError.unreadable }
        try persist(templates.filter { $0.id != id })
    }

    private func persist(_ updated: [NoteTemplate]) throws {
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: Self.storageKey)
        templates = updated
    }

    public enum LibraryError: Error, Equatable {
        case missingName
        case unreadable
    }
}
