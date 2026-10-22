import XCTest
@testable import YoPDFCore

/// Built-in template inventory, seed semantics, and the corruption-safe user
/// template library.
@MainActor
final class NoteTemplateTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "YoPDFNoteTemplateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func cleanUp(_ defaults: UserDefaults, _ suite: String) {
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - Built-ins

    func testAllTwelveBuiltInsHaveTheReferenceIdentityAndOutline() {
        let templates = NoteTemplate.builtIns()
        XCTAssertEqual(templates.count, 12)
        XCTAssertEqual(Set(templates.map(\.id)).count, 12)
        XCTAssertEqual(
            templates.map(\.style.title),
            [
                "Blank", "Insight", "Question", "Summary", "Method", "Evidence",
                "Limitation", "To Verify", "Connection", "Next Step", "Quote", "Review",
            ]
        )
        XCTAssertEqual(
            templates.map(\.style.palette),
            [.honey, .honey, .sky, .sand, .mint, .sky, .rose, .lavender, .mint, .honey, .sand, .lavender]
        )
        XCTAssertEqual(
            templates.map(\.style.motif),
            [.bunny, .star, .cloud, .letter, .botanical, .roseStamp, .heart, .cherry, .flower, .bow, .washi, .cat]
        )
        XCTAssertEqual(
            templates.map(\.style.symbol),
            [
                "note.text", "lightbulb", "questionmark.bubble", "text.alignleft",
                "slider.horizontal.3", "chart.bar", "exclamationmark.triangle", "flask",
                "link", "checklist", "quote.opening", "text.badge.checkmark",
            ]
        )
        XCTAssertEqual(templates.first?.body, "", "Blank has no outline")
        XCTAssertEqual(
            templates.first { $0.id == "builtin.insight" }?.body,
            "Key insight:\n\nWhy it matters:\n"
        )
        XCTAssertEqual(
            templates.first { $0.id == "builtin.review" }?.body,
            "Strength:\n\nConcern:\n\nRecommendation:\n"
        )
    }

    // MARK: - Applying and seeds

    func testTemplateSeedsOnlyAnEmptyOrUntouchedOutline() {
        let insight = NoteTemplate.builtIns().first { $0.id == "builtin.insight" }!
        let question = NoteTemplate.builtIns().first { $0.id == "builtin.question" }!

        XCTAssertEqual(insight.applying(to: "", previousSeed: nil), insight.body)
        XCTAssertEqual(insight.applying(to: "   \n", previousSeed: nil), insight.body)
        XCTAssertEqual(insight.applying(to: "My own words", previousSeed: nil), "My own words")
        XCTAssertEqual(insight.applying(to: question.body, previousSeed: question.body), insight.body)
        XCTAssertEqual(insight.applying(to: "My own words", previousSeed: question.body), "My own words")
    }

    func testTemplateSelectionRecognizesAnUntouchedOutlineAfterAppearanceChanges() {
        let templates = NoteTemplate.builtIns()
        let insight = templates.first { $0.id == "builtin.insight" }!
        let question = templates.first { $0.id == "builtin.question" }!

        var selection = NoteTemplateSelection()
        selection.restoreIfNeeded(text: insight.body, templates: templates)
        XCTAssertEqual(selection.seed, insight.body)

        // The popover may be rebuilt with a template list that no longer
        // contains the original template. The seed must still be remembered.
        selection.restoreIfNeeded(
            text: insight.body,
            templates: templates.filter { $0.id != insight.id }
        )
        XCTAssertEqual(selection.seed, insight.body)

        // A different appearance is irrelevant: matching is by body only.
        let seeded = selection.apply(question, to: insight.body)
        XCTAssertEqual(seeded, question.body)
        XCTAssertEqual(selection.seed, question.body)
    }

    func testUserTextIsNeverReplacedByATemplate() {
        var selection = NoteTemplateSelection()
        selection.restoreIfNeeded(text: "My own words", templates: NoteTemplate.builtIns())
        XCTAssertNil(selection.seed)

        let insight = NoteTemplate.builtIns().first { $0.id == "builtin.insight" }!
        XCTAssertEqual(selection.apply(insight, to: "My own words"), "My own words")
        XCTAssertEqual(selection.seed, insight.body)
    }

    func testTemplateSelectionResets() {
        var selection = NoteTemplateSelection()
        selection.restoreIfNeeded(
            text: NoteTemplate.builtIns()[1].body,
            templates: NoteTemplate.builtIns()
        )
        XCTAssertNotNil(selection.seed)
        selection.reset()
        XCTAssertNil(selection.seed)
    }

    // MARK: - User template persistence

    func testUserTemplateRoundTripsThroughUserDefaults() throws {
        let (defaults, suite) = makeDefaults()
        defer { cleanUp(defaults, suite) }

        let store = NoteTemplateStore(defaults: defaults)
        XCTAssertFalse(store.loadFailed)
        XCTAssertTrue(store.templates.isEmpty)

        let saved = try store.save(
            style: NoteStickerStyle(
                motif: .letter,
                palette: .sand,
                title: "  My Summary  ",
                symbol: "text.alignleft"
            ),
            body: "My outline:\n"
        )
        XCTAssertEqual(saved.style.title, "My Summary", "the stored title is trimmed")
        XCTAssertEqual(store.templates.count, 1)

        let reopened = NoteTemplateStore(defaults: defaults)
        XCTAssertFalse(reopened.loadFailed)
        XCTAssertEqual(reopened.templates, [saved])
        XCTAssertEqual(reopened.templates.first?.style.motif, .letter)
        XCTAssertEqual(reopened.templates.first?.style.palette, .sand)
        XCTAssertEqual(reopened.templates.first?.body, "My outline:\n")
    }

    func testUpdatingAUserTemplateKeepsItsIdentityAndDoesNotDuplicateIt() throws {
        let (defaults, suite) = makeDefaults()
        defer { cleanUp(defaults, suite) }
        let store = NoteTemplateStore(defaults: defaults)

        let saved = try store.save(
            style: NoteStickerStyle(palette: .mint, title: "First", symbol: "link"),
            body: "One"
        )
        let updated = try store.save(
            id: saved.id,
            style: NoteStickerStyle(palette: .rose, title: "Renamed", symbol: "heart"),
            body: "Two"
        )

        XCTAssertEqual(updated.id, saved.id)
        XCTAssertEqual(store.templates.count, 1)
        XCTAssertEqual(store.templates.first?.style.title, "Renamed")
        XCTAssertEqual(store.templates.first?.body, "Two")
    }

    func testDeletingAUserTemplatePersists() throws {
        let (defaults, suite) = makeDefaults()
        defer { cleanUp(defaults, suite) }
        let store = NoteTemplateStore(defaults: defaults)
        let saved = try store.save(
            style: NoteStickerStyle(palette: .sky, title: "Delete me"),
            body: ""
        )
        try store.delete(id: saved.id)

        XCTAssertTrue(store.templates.isEmpty)
        let reopened = NoteTemplateStore(defaults: defaults)
        XCTAssertTrue(reopened.templates.isEmpty)
    }

    func testUnreadableLibraryIsKeptAndNeverOverwritten() throws {
        let (defaults, suite) = makeDefaults()
        defer { cleanUp(defaults, suite) }
        let corrupted = Data("{not a template library".utf8)
        defaults.set(corrupted, forKey: NoteTemplateStore.storageKey)

        let store = NoteTemplateStore(defaults: defaults)
        XCTAssertTrue(store.loadFailed)
        XCTAssertTrue(store.templates.isEmpty)

        XCTAssertThrowsError(
            try store.save(
                style: NoteStickerStyle(palette: .honey, title: "Should not save"),
                body: "Nope"
            )
        ) { error in
            XCTAssertEqual(error as? NoteTemplateStore.LibraryError, .unreadable)
        }
        XCTAssertEqual(
            defaults.data(forKey: NoteTemplateStore.storageKey),
            corrupted,
            "the original bytes must survive a refused write"
        )
    }

    func testTemplateWithoutANameIsRefused() {
        let (defaults, suite) = makeDefaults()
        defer { cleanUp(defaults, suite) }
        let store = NoteTemplateStore(defaults: defaults)

        XCTAssertThrowsError(
            try store.save(
                style: NoteStickerStyle(palette: .honey, title: "  \n"),
                body: "Body"
            )
        ) { error in
            XCTAssertEqual(error as? NoteTemplateStore.LibraryError, .missingName)
        }
        XCTAssertTrue(store.templates.isEmpty)
    }

    func testLegacyTemplateJSONWithoutTitleOrSymbolStillDecodes() throws {
        let json = Data("""
        [{"id":"legacy","style":{"motif":"cat","palette":"rose"},"body":"Legacy outline"}]
        """.utf8)
        let templates = try JSONDecoder().decode([NoteTemplate].self, from: json)
        XCTAssertEqual(templates.count, 1)
        XCTAssertEqual(templates.first?.id, "legacy")
        XCTAssertEqual(templates.first?.style.motif, .cat)
        XCTAssertEqual(templates.first?.style.palette, .rose)
        XCTAssertEqual(templates.first?.style.title, "")
        XCTAssertEqual(templates.first?.style.symbol, NoteStickerStyle.defaultSymbol)
        XCTAssertEqual(templates.first?.body, "Legacy outline")
    }

    func testTemplateStyleRoundTripsThroughJSONWithUnicodeAndQuotes() throws {
        let template = NoteTemplate(
            id: "custom.1",
            style: NoteStickerStyle(
                motif: .washi,
                palette: .lavender,
                title: "引用 \"Quote\"",
                symbol: "quote.opening"
            ),
            body: "先读这一句。\n"
        )
        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(NoteTemplate.self, from: data)
        XCTAssertEqual(decoded, template)
    }
}
