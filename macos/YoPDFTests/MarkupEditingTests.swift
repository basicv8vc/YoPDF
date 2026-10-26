import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

/// P2b markup editing through the reader model, against real PDFs and PDFKit.
///
/// Every assertion here runs on a document on disk: annotation geometry, the
/// saved `/C` entry, undo history and permission flags are all PDFKit concepts,
/// and a mock would test the mock instead.
@MainActor
final class MarkupEditingTests: XCTestCase {

    /// `tearDown()` is nonisolated in XCTest, so the cleanup lists cannot be
    /// main-actor isolated. Tests run serially; nothing else touches them.
    nonisolated(unsafe) private var temporaryFiles: [URL] = []
    nonisolated(unsafe) private var defaultsSuites: [String] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        temporaryFiles.removeAll()

        for suite in defaultsSuites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        defaultsSuites.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures and helpers

    private func makeSuite() -> String {
        let suite = "dev.yopdf.tests.markup.\(UUID().uuidString)"
        defaultsSuites.append(suite)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        return suite
    }

    private func makeModel(
        suite: String? = nil,
        io: any DocumentStoreIO = SystemDocumentStoreIO()
    ) -> PDFDocumentModel {
        let suite = suite ?? makeSuite()
        let defaults = UserDefaults(suiteName: suite)!
        return PDFDocumentModel(
            access: SecurityScopeSpy(),
            io: io,
            markupPreferences: MarkupColorPreferences(defaults: defaults)
        )
    }

    private func makeFixture(
        pageCount: Int = 2,
        linesPerPage: Int = 4,
        named name: String = "markup"
    ) throws -> URL {
        let url = try PDFFixtureFactory.writeTemporaryParagraphPDF(
            pageCount: pageCount,
            linesPerPage: linesPerPage,
            named: name
        )
        temporaryFiles.append(url)
        return url
    }

    /// An encrypted copy of `document` whose access permissions forbid
    /// commenting.
    ///
    /// PDFKit exposes `allowsCommenting` as read-only and derives it from the
    /// encryption dictionary, so the only reliable way to produce this case is
    /// to write a document with an owner password and no commenting permission.
    /// No user password is set, so the file still opens without a prompt.
    ///
    /// The copy is made after any annotations are added: PDFKit itself refuses
    /// `addAnnotation` on a document whose permissions are already restricted.
    private func makeCommentingRestrictedCopy(
        of document: PDFDocument,
        named name: String = "restricted"
    ) throws -> URL {
        let source = try XCTUnwrap(document.documentURL)
        let restricted = source.deletingLastPathComponent()
            .appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
        let wrote = document.write(
            to: restricted,
            withOptions: [
                PDFDocumentWriteOption.ownerPasswordOption: "yopdf-test-owner",
                PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: 1 << 0)
            ]
        )
        XCTAssertTrue(wrote, "the restricted fixture must be written")
        temporaryFiles.append(restricted)

        let reopened = try XCTUnwrap(PDFDocument(url: restricted))
        XCTAssertFalse(
            reopened.allowsCommenting,
            "the fixture must actually forbid commenting"
        )
        return restricted
    }

    private func setFlags(_ flags: Int, on annotation: PDFAnnotation) {
        annotation.setValue(NSNumber(value: flags), forAnnotationKey: .flags)
    }

    private func selection(
        in document: PDFDocument,
        pageIndex: Int,
        from start: Int,
        to end: Int
    ) throws -> PDFSelection {
        let page = try XCTUnwrap(document.page(at: pageIndex))
        let length = (page.string ?? "").count
        let lower = min(max(start, 0), max(length - 1, 0))
        let upper = min(max(end, lower + 1), length)
        return try XCTUnwrap(
            document.selection(from: page, atCharacterIndex: lower, to: page, atCharacterIndex: upper)
        )
    }

    private func wholePageSelection(
        in document: PDFDocument,
        pageIndex: Int
    ) throws -> PDFSelection {
        let page = try XCTUnwrap(document.page(at: pageIndex))
        let length = (page.string ?? "").count
        return try XCTUnwrap(
            document.selection(from: page, atCharacterIndex: 0, to: page, atCharacterIndex: length)
        )
    }

    private func crossPageSelection(
        in document: PDFDocument,
        fromPage: Int,
        toPage: Int,
        startOffsetFromEnd: Int = 20,
        endCharacter: Int = 60
    ) throws -> PDFSelection {
        let first = try XCTUnwrap(document.page(at: fromPage))
        let second = try XCTUnwrap(document.page(at: toPage))
        let firstLength = (first.string ?? "").count
        let secondLength = (second.string ?? "").count
        return try XCTUnwrap(
            document.selection(
                from: first,
                atCharacterIndex: max(firstLength - startOffsetFromEnd, 0),
                to: second,
                atCharacterIndex: min(max(endCharacter, 0), max(secondLength - 1, 0))
            )
        )
    }

    @discardableResult
    private func addMarkup(
        _ kind: MarkupKind,
        to model: PDFDocumentModel,
        selection: PDFSelection
    ) throws -> HighlightService.Summary {
        model.updateSelection(selection)
        return try XCTUnwrap(model.addMarkup(kind))
    }

    private func firstMarkup(
        on pageIndex: Int,
        in model: PDFDocumentModel,
        kind: MarkupKind? = nil
    ) throws -> PDFAnnotation {
        let page = try XCTUnwrap(model.document?.page(at: pageIndex))
        let annotation = page.annotations.first { annotation in
            let annotationKind = MarkupKind(annotation: annotation)
            return annotationKind != nil && (kind == nil || annotationKind == kind)
        }
        return try XCTUnwrap(annotation)
    }

    private func selectMarkup(
        _ annotation: PDFAnnotation,
        in model: PDFDocumentModel,
        pageIndex: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let page = try XCTUnwrap(model.document?.page(at: pageIndex))
        let rect = try XCTUnwrap(MarkupGeometry.quadRects(for: annotation).first)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        XCTAssertTrue(
            model.selectMarkup(at: point, on: page),
            "the centre of a painted quad must select the annotation",
            file: file,
            line: line
        )
    }

    private func hex(_ color: NSColor) -> String {
        MarkupColorPalette.hex(from: color) ?? ""
    }

    // MARK: - Defaults

    func testDefaultColoursAreIndependentAndPersist() throws {
        let suite = makeSuite()
        let model = makeModel(suite: suite)

        XCTAssertEqual(hex(model.defaultMarkupColor(for: .highlight)), "FFD60A")
        XCTAssertEqual(hex(model.defaultMarkupColor(for: .underline)), "007AFF")

        let green = MarkupColorPalette.color(fromHex: "34C759")
        XCTAssertTrue(model.setDefaultMarkupColor(green, for: .highlight))
        XCTAssertEqual(hex(model.defaultMarkupColor(for: .highlight)), "34C759")
        XCTAssertEqual(
            hex(model.defaultMarkupColor(for: .underline)),
            "007AFF",
            "changing Highlight must not change Underline"
        )

        let reopenedModel = makeModel(suite: suite)
        XCTAssertEqual(hex(reopenedModel.defaultMarkupColor(for: .highlight)), "34C759")
        XCTAssertEqual(hex(reopenedModel.defaultMarkupColor(for: .underline)), "007AFF")
    }

    func testCustomColourIsStoredOpaqueAndTransparentIsRejected() throws {
        let model = makeModel()
        let translucent = NSColor(srgbRed: 0.12, green: 0.34, blue: 0.56, alpha: 0.4)

        XCTAssertTrue(model.setDefaultMarkupColor(translucent, for: .highlight))
        let stored = model.defaultMarkupColor(for: .highlight)
        XCTAssertEqual(hex(stored), "1F578F")
        XCTAssertEqual(stored.alphaComponent, 1.0, accuracy: 0.001)

        XCTAssertFalse(
            model.setDefaultMarkupColor(.clear, for: .highlight),
            "a fully transparent colour would be invisible in the PDF"
        )
        XCTAssertEqual(hex(model.defaultMarkupColor(for: .highlight)), "1F578F")
        XCTAssertNil(MarkupColorPalette.normalized(NSColor(white: 0.5, alpha: 0)))
    }

    // MARK: - Creation

    func testHighlightAndUnderlineUseTheirOwnDefaults() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        let page = try XCTUnwrap(document.page(at: 0))

        let selection = try wholePageSelection(in: document, pageIndex: 0)
        let highlight = try addMarkup(.highlight, to: model, selection: selection)
        XCTAssertEqual(highlight.annotationCount, 1)
        XCTAssertEqual(highlight.pageIndices, [0])
        let highlightAnnotation = try firstMarkup(on: 0, in: model, kind: .highlight)
        XCTAssertEqual(hex(highlightAnnotation.color), "FFD60A")
        XCTAssertEqual(highlightAnnotation.quadrilateralPoints?.count, highlight.quadCount * 4)

        let underlineSelection = try self.selection(in: document, pageIndex: 0, from: 0, to: 8)
        let underline = try addMarkup(.underline, to: model, selection: underlineSelection)
        XCTAssertEqual(underline.annotationCount, 1)
        let underlineAnnotation = try firstMarkup(on: 0, in: model, kind: .underline)
        XCTAssertEqual(hex(underlineAnnotation.color), "007AFF")
        XCTAssertTrue(underlineAnnotation.isMarkupType("Underline"))
        XCTAssertFalse(underlineAnnotation.isMarkupType("Highlight"))

        XCTAssertEqual(page.annotations.filter(\.isMarkup).count, 2)
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    func testEditingAnAnnotationsColourDoesNotChangeTheNewMarkDefault() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)

        let firstSelection = try selection(in: document, pageIndex: 0, from: 0, to: 8)
        try addMarkup(.highlight, to: model, selection: firstSelection)
        let annotation = try firstMarkup(on: 0, in: model)
        try selectMarkup(annotation, in: model)

        XCTAssertTrue(model.recolorSelectedMarkup(to: MarkupColorPalette.color(fromHex: "FF2D55")))
        XCTAssertEqual(hex(annotation.color), "FF2D55")
        XCTAssertEqual(
            hex(model.defaultMarkupColor(for: .highlight)),
            "FFD60A",
            "editing one mark is not a preference change"
        )

        let secondSelection = try selection(in: document, pageIndex: 0, from: 10, to: 18)
        try addMarkup(.highlight, to: model, selection: secondSelection)
        let markings = try XCTUnwrap(model.document?.page(at: 0)?.annotations.filter(\.isMarkup))
        XCTAssertEqual(markings.count, 2)
        let newAnnotation = try XCTUnwrap(markings.first { $0 !== annotation })
        XCTAssertEqual(hex(newAnnotation.color), "FFD60A")
    }

    // MARK: - Hit testing

    func testHitTestingUsesQuadsAndRejectsTheBoundingBoxGap() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 4)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        let page = try XCTUnwrap(document.page(at: 0))

        let selection = try wholePageSelection(in: document, pageIndex: 0)
        try addMarkup(.highlight, to: model, selection: selection)
        let annotation = try firstMarkup(on: 0, in: model)
        let rects = MarkupGeometry.quadRects(for: annotation)
        XCTAssertGreaterThanOrEqual(rects.count, 2)
        XCTAssertGreaterThan(rects[1].width, rects[0].width, "the fixture's second line is longer")

        // Inside the annotation's bounds, but to the right of the short first
        // line and therefore in the gap between the painted quads.
        let gap = CGPoint(
            x: (rects[0].maxX + rects[1].maxX) / 2,
            y: rects[0].midY
        )
        XCTAssertTrue(annotation.bounds.contains(gap))
        XCTAssertFalse(rects.contains { $0.contains(gap) })
        XCTAssertFalse(
            model.selectMarkup(at: gap, on: page),
            "the empty area inside a multi-line bounding box is not the annotation"
        )
        XCTAssertNil(model.selectedMarkup)

        let inside = CGPoint(x: rects[0].midX, y: rects[0].midY)
        XCTAssertTrue(model.selectMarkup(at: inside, on: page))
        XCTAssertEqual(model.selectedMarkup?.kind, .highlight)
        XCTAssertEqual(model.selectedMarkup?.pageIndex, 0)
    }

    func testHiddenMarkupCannotBeSelected() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        try addMarkup(
            .highlight,
            to: model,
            selection: try selection(in: document, pageIndex: 0, from: 0, to: 8)
        )
        let annotation = try firstMarkup(on: 0, in: model)
        annotation.shouldDisplay = false

        let page = try XCTUnwrap(document.page(at: 0))
        let rect = try XCTUnwrap(MarkupGeometry.quadRects(for: annotation).first)
        XCTAssertFalse(
            model.selectMarkup(at: CGPoint(x: rect.midX, y: rect.midY), on: page),
            "a hidden annotation is not a click target"
        )
        XCTAssertNil(model.selectedMarkup)
    }

    // MARK: - Recolour

    func testRecolourIsUndoableAndAColourGestureIsOneAction() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)

        let selection = try selection(in: document, pageIndex: 0, from: 0, to: 10)
        try addMarkup(.highlight, to: model, selection: selection)
        let annotation = try firstMarkup(on: 0, in: model)
        try selectMarkup(annotation, in: model)

        var revisions = [model.editRevision]
        XCTAssertTrue(model.recolorSelectedMarkup(to: MarkupColorPalette.color(fromHex: "FF2D55")))
        revisions.append(model.editRevision)
        XCTAssertTrue(model.recolorSelectedMarkup(to: MarkupColorPalette.color(fromHex: "AF52DE")))
        revisions.append(model.editRevision)
        XCTAssertTrue(model.recolorSelectedMarkup(to: MarkupColorPalette.color(fromHex: "FF9500")))
        revisions.append(model.editRevision)

        XCTAssertEqual(hex(annotation.color), "FF9500")
        XCTAssertGreaterThan(revisions[1], revisions[0])
        XCTAssertGreaterThan(revisions[2], revisions[1])
        XCTAssertGreaterThan(revisions[3], revisions[2])

        // One undo returns the original yellow, not the intermediate pink or
        // purple. The add remains as the next entry.
        XCTAssertTrue(model.undoMarkup())
        XCTAssertEqual(hex(annotation.color), "FFD60A")
        XCTAssertTrue(model.canUndoMarkup, "the add is still undoable")
        XCTAssertTrue(model.canRedoMarkup)
        XCTAssertTrue(model.hasUnsavedChanges)

        XCTAssertTrue(model.redoMarkup())
        XCTAssertEqual(hex(annotation.color), "FF9500")
        XCTAssertFalse(model.canRedoMarkup)
    }

    func testTransparentRecolourIsRejectedWithoutAnEdit() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 2)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        try addMarkup(
            .highlight,
            to: model,
            selection: try selection(in: document, pageIndex: 0, from: 0, to: 8)
        )
        let annotation = try firstMarkup(on: 0, in: model)
        try selectMarkup(annotation, in: model)

        let revision = model.editRevision
        let undoCount = model.canUndoMarkup
        XCTAssertFalse(model.recolorSelectedMarkup(to: .clear))
        XCTAssertEqual(hex(annotation.color), "FFD60A")
        XCTAssertEqual(model.editRevision, revision)
        XCTAssertEqual(model.canUndoMarkup, undoCount)
    }

    // MARK: - Add, delete, convert and undo

    func testCrossPageAddIsOneUndoAction() throws {
        let url = try makeFixture(pageCount: 2, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)

        let selection = try crossPageSelection(in: document, fromPage: 0, toPage: 1)
        XCTAssertEqual(selection.pages.count, 2)
        let revisionBefore = model.annotationRevision
        let summary = try addMarkup(.underline, to: model, selection: selection)
        XCTAssertEqual(summary.annotationCount, 2)
        XCTAssertEqual(model.annotationRevision, revisionBefore + 1)
        XCTAssertEqual(model.changedAnnotationPageIndices, [0, 1])
        XCTAssertEqual(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).count, 1)
        XCTAssertEqual(model.document?.page(at: 1)?.annotations.filter(\.isMarkup).count, 1)
        XCTAssertTrue(model.canUndoMarkup)

        let revisionAfterAdd = model.editRevision
        XCTAssertTrue(model.undoMarkup())
        XCTAssertGreaterThan(model.editRevision, revisionAfterAdd)
        XCTAssertEqual(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).count, 0)
        XCTAssertEqual(model.document?.page(at: 1)?.annotations.filter(\.isMarkup).count, 0)
        XCTAssertFalse(model.canUndoMarkup, "both pages were one undo entry")
        XCTAssertTrue(model.canRedoMarkup)
        XCTAssertTrue(model.hasUnsavedChanges)

        let revisionAfterUndo = model.editRevision
        XCTAssertTrue(model.redoMarkup())
        XCTAssertGreaterThan(model.editRevision, revisionAfterUndo)
        XCTAssertEqual(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).count, 1)
        XCTAssertEqual(model.document?.page(at: 1)?.annotations.filter(\.isMarkup).count, 1)
        XCTAssertFalse(model.canRedoMarkup)
    }

    func testDeleteAndUndoRestoreTheSameAnnotation() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        try addMarkup(
            .highlight,
            to: model,
            selection: try wholePageSelection(in: document, pageIndex: 0)
        )
        let annotation = try firstMarkup(on: 0, in: model)
        let bounds = annotation.bounds
        let quads = annotation.quadrilateralPoints
        try selectMarkup(annotation, in: model)

        XCTAssertTrue(model.deleteSelectedMarkup())
        XCTAssertNil(model.selectedMarkup)
        XCTAssertTrue(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).isEmpty ?? false)
        XCTAssertTrue(model.hasUnsavedChanges)

        XCTAssertTrue(model.undoMarkup())
        let restored = try firstMarkup(on: 0, in: model)
        XCTAssertTrue(restored === annotation, "undo restores the same PDFAnnotation")
        XCTAssertEqual(restored.bounds, bounds)
        XCTAssertEqual(restored.quadrilateralPoints, quads)
        XCTAssertEqual(hex(restored.color), "FFD60A")
        XCTAssertTrue(model.canRedoMarkup)

        XCTAssertTrue(model.redoMarkup())
        XCTAssertTrue(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).isEmpty ?? false)
    }

    func testConversionPreservesMetadataAndIsUndoable() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        try addMarkup(
            .highlight,
            to: model,
            selection: try wholePageSelection(in: document, pageIndex: 0)
        )
        let original = try firstMarkup(on: 0, in: model)
        original.contents = "Existing note text"
        original.userName = "Reviewer"
        original.setValue("annotation-id-1", forAnnotationKey: .name)
        original.setValue(NSNumber(value: 4), forAnnotationKey: .flags)
        let originalBounds = original.bounds
        let originalQuads = original.quadrilateralPoints

        try selectMarkup(original, in: model)
        XCTAssertTrue(model.convertSelectedMarkup())

        let converted = try firstMarkup(on: 0, in: model)
        XCTAssertTrue(converted.isMarkupType("Underline"))
        XCTAssertFalse(converted.isMarkupType("Highlight"))
        XCTAssertEqual(converted.contents, "Existing note text")
        XCTAssertEqual(converted.userName, "Reviewer")
        XCTAssertEqual(
            converted.value(forAnnotationKey: .name) as? String,
            "annotation-id-1"
        )
        XCTAssertEqual(
            (converted.value(forAnnotationKey: .flags) as? NSNumber)?.intValue,
            4
        )
        XCTAssertEqual(converted.bounds, originalBounds)
        XCTAssertEqual(converted.quadrilateralPoints, originalQuads)
        XCTAssertEqual(hex(converted.color), "FFD60A")
        XCTAssertEqual(model.selectedMarkup?.kind, .underline)

        XCTAssertTrue(model.undoMarkup())
        let restored = try firstMarkup(on: 0, in: model)
        XCTAssertTrue(restored.isMarkupType("Highlight"))
        XCTAssertEqual(restored.contents, "Existing note text")
        XCTAssertEqual(
            restored.value(forAnnotationKey: .name) as? String,
            "annotation-id-1"
        )

        XCTAssertTrue(model.redoMarkup())
        XCTAssertTrue(try firstMarkup(on: 0, in: model).isMarkupType("Underline"))
    }

    // MARK: - Protection

    func testReadOnlyAndLockedAnnotationsCannotBeEdited() throws {
        for flag in [MarkupPermissions.readOnlyFlag, MarkupPermissions.lockedFlag] {
            let url = try makeFixture(pageCount: 1, linesPerPage: 2, named: "protected-\(flag)")
            let model = makeModel()
            XCTAssertTrue(model.open(url: url))
            let document = try XCTUnwrap(model.document)
            try addMarkup(
                .highlight,
                to: model,
                selection: try selection(in: document, pageIndex: 0, from: 0, to: 8)
            )
            let annotation = try firstMarkup(on: 0, in: model)
            annotation.setValue(NSNumber(value: flag), forAnnotationKey: .flags)
            try selectMarkup(annotation, in: model)

            XCTAssertTrue(model.selectedMarkupIsProtected)
            XCTAssertFalse(model.canModifySelectedMarkup)
            let revision = model.editRevision

            XCTAssertFalse(model.recolorSelectedMarkup(to: MarkupColorPalette.color(fromHex: "34C759")))
            XCTAssertFalse(model.deleteSelectedMarkup())
            XCTAssertFalse(model.convertSelectedMarkup())
            XCTAssertEqual(hex(annotation.color), "FFD60A")
            XCTAssertEqual(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).count, 1)
            XCTAssertEqual(model.editRevision, revision, "a refused edit is not an edit")
        }
    }

    // MARK: - Undo/Redo permissions

    func testUndoRefusesToRemoveALockedAnnotationUntilUnlocked() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        try addMarkup(
            .highlight,
            to: model,
            selection: try selection(in: document, pageIndex: 0, from: 0, to: 10)
        )
        let annotation = try firstMarkup(on: 0, in: model)
        try selectMarkup(annotation, in: model)
        setFlags(MarkupPermissions.lockedFlag, on: annotation)
        let revision = model.editRevision

        XCTAssertTrue(model.selectedMarkupIsProtected)
        XCTAssertFalse(model.undoMarkup())
        XCTAssertEqual(
            model.document?.page(at: 0)?.annotations.filter(\.isMarkup).count,
            1,
            "a locked mark must not be removed by Undo"
        )
        XCTAssertEqual(model.editRevision, revision, "a refused Undo is not an edit")
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.canUndoMarkup, "the history must survive the refusal")
        XCTAssertFalse(model.canRedoMarkup)
        XCTAssertNotNil(model.selectedMarkup, "the protected mark stays selectable")

        setFlags(0, on: annotation)
        XCTAssertTrue(model.undoMarkup())
        XCTAssertTrue(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).isEmpty ?? false)
        XCTAssertGreaterThan(model.editRevision, revision)
        XCTAssertTrue(model.canRedoMarkup)

        XCTAssertTrue(model.redoMarkup())
        XCTAssertEqual(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).count, 1)
        XCTAssertFalse(model.canRedoMarkup)
    }

    func testUndoRefusesToRecolourAReadOnlyAnnotationUntilUnlocked() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        try addMarkup(
            .highlight,
            to: model,
            selection: try selection(in: document, pageIndex: 0, from: 0, to: 10)
        )
        let annotation = try firstMarkup(on: 0, in: model)
        try selectMarkup(annotation, in: model)
        XCTAssertTrue(model.recolorSelectedMarkup(to: MarkupColorPalette.color(fromHex: "FF2D55")))
        setFlags(MarkupPermissions.readOnlyFlag, on: annotation)
        let revision = model.editRevision

        XCTAssertFalse(model.undoMarkup())
        XCTAssertEqual(
            hex(annotation.color),
            "FF2D55",
            "Undo must not change the colour of a ReadOnly annotation"
        )
        XCTAssertEqual(model.editRevision, revision)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.canUndoMarkup)
        XCTAssertNotNil(model.selectedMarkup)

        setFlags(0, on: annotation)
        XCTAssertTrue(model.undoMarkup())
        XCTAssertEqual(hex(annotation.color), "FFD60A")
        XCTAssertTrue(model.canUndoMarkup, "the add is still the next undo entry")
        XCTAssertTrue(model.undoMarkup())
        XCTAssertTrue(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).isEmpty ?? false)
    }

    func testRedoRefusesToDeleteAnAnnotationLockedAfterUndo() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        try addMarkup(
            .highlight,
            to: model,
            selection: try selection(in: document, pageIndex: 0, from: 0, to: 10)
        )
        let annotation = try firstMarkup(on: 0, in: model)
        try selectMarkup(annotation, in: model)
        XCTAssertTrue(model.deleteSelectedMarkup())
        XCTAssertTrue(model.undoMarkup())
        let restored = try firstMarkup(on: 0, in: model)
        XCTAssertTrue(restored === annotation)
        setFlags(MarkupPermissions.lockedFlag, on: restored)
        let revision = model.editRevision

        XCTAssertFalse(model.redoMarkup())
        XCTAssertEqual(
            model.document?.page(at: 0)?.annotations.filter(\.isMarkup).count,
            1,
            "a locked restored mark must not be deleted by Redo"
        )
        XCTAssertEqual(model.editRevision, revision)
        XCTAssertTrue(model.canRedoMarkup)
        XCTAssertTrue(model.hasUnsavedChanges)

        setFlags(0, on: restored)
        XCTAssertTrue(model.redoMarkup())
        XCTAssertTrue(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).isEmpty ?? false)
    }

    func testCrossPageUndoIsAtomicWhenOnePageIsLocked() throws {
        let url = try makeFixture(pageCount: 2, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)

        let selection = try crossPageSelection(in: document, fromPage: 0, toPage: 1)
        try addMarkup(.highlight, to: model, selection: selection)
        let pageOneAnnotation = try firstMarkup(on: 1, in: model)
        setFlags(MarkupPermissions.lockedFlag, on: pageOneAnnotation)
        let revision = model.editRevision

        XCTAssertFalse(model.undoMarkup())
        XCTAssertEqual(
            model.document?.page(at: 0)?.annotations.filter(\.isMarkup).count,
            1,
            "Undo must not remove the editable page of a blocked cross-page edit"
        )
        XCTAssertEqual(
            model.document?.page(at: 1)?.annotations.filter(\.isMarkup).count,
            1
        )
        XCTAssertEqual(model.editRevision, revision)
        XCTAssertTrue(model.canUndoMarkup)
        XCTAssertFalse(model.canRedoMarkup)

        setFlags(0, on: pageOneAnnotation)
        XCTAssertTrue(model.undoMarkup())
        XCTAssertTrue(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).isEmpty ?? false)
        XCTAssertTrue(model.document?.page(at: 1)?.annotations.filter(\.isMarkup).isEmpty ?? false)
        XCTAssertFalse(model.canUndoMarkup)

        XCTAssertTrue(model.redoMarkup())
        XCTAssertEqual(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).count, 1)
        XCTAssertEqual(model.document?.page(at: 1)?.annotations.filter(\.isMarkup).count, 1)
    }

    func testConversionUndoRefusesALockedReplacement() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        try addMarkup(
            .highlight,
            to: model,
            selection: try selection(in: document, pageIndex: 0, from: 0, to: 10)
        )
        try selectMarkup(try firstMarkup(on: 0, in: model), in: model)
        XCTAssertTrue(model.convertSelectedMarkup())
        let replacement = try firstMarkup(on: 0, in: model)
        XCTAssertTrue(replacement.isMarkupType("Underline"))
        setFlags(MarkupPermissions.lockedFlag, on: replacement)
        let revision = model.editRevision

        XCTAssertFalse(model.undoMarkup())
        XCTAssertEqual(
            model.document?.page(at: 0)?.annotations.filter(\.isMarkup).count,
            1
        )
        XCTAssertTrue(try firstMarkup(on: 0, in: model).isMarkupType("Underline"))
        XCTAssertEqual(model.editRevision, revision)
        XCTAssertTrue(model.canUndoMarkup)

        setFlags(0, on: replacement)
        XCTAssertTrue(model.undoMarkup())
        let restored = try firstMarkup(on: 0, in: model)
        XCTAssertTrue(restored.isMarkupType("Highlight"))
        XCTAssertTrue(model.canRedoMarkup)

        XCTAssertTrue(model.redoMarkup())
        XCTAssertTrue(try firstMarkup(on: 0, in: model).isMarkupType("Underline"))
    }

    func testHistoryReplayRefusesWhenTheDocumentDisallowsCommenting() throws {
        let source = try makeFixture(pageCount: 1, linesPerPage: 3, named: "restricted-source")
        let sourceDocument = try XCTUnwrap(PDFDocument(url: source))
        let sourceSelection = try selection(in: sourceDocument, pageIndex: 0, from: 0, to: 10)
        _ = try HighlightService.addMarkup(
            .highlight,
            from: sourceSelection,
            to: sourceDocument
        )
        let url = try makeCommentingRestrictedCopy(of: sourceDocument)

        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertFalse(document.allowsCommenting)
        let annotation = try firstMarkup(on: 0, in: model)

        // The annotation predates the encryption, but the model must still
        // refuse every operation that would change it.
        let selection = try selection(in: document, pageIndex: 0, from: 0, to: 10)
        model.updateSelection(selection)
        XCTAssertFalse(model.canAddMarkup(.highlight))
        XCTAssertNil(model.addMarkup(.highlight))
        XCTAssertEqual(page.annotations.filter(\.isMarkup).count, 1)
        try selectMarkup(annotation, in: model)
        XCTAssertFalse(model.recolorSelectedMarkup(to: MarkupColorPalette.color(fromHex: "34C759")))
        XCTAssertFalse(model.deleteSelectedMarkup())
        XCTAssertFalse(model.convertSelectedMarkup())

        model.markupUndoStack.append(MarkupEdit(changes: [
            .insert(annotation: annotation, pageIndex: 0)
        ]))
        model.canUndoMarkup = true
        let revision = model.editRevision

        XCTAssertFalse(model.undoMarkup())
        XCTAssertEqual(
            page.annotations.filter(\.isMarkup).count,
            1,
            "a document that forbids commenting must not lose an annotation to Undo"
        )
        XCTAssertEqual(model.editRevision, revision)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertTrue(model.canUndoMarkup, "a permission refusal must preserve the history")
        XCTAssertNotNil(model.selectedMarkup)
    }

    // MARK: - Saving

    func testEditingOneMarkupPreservesThirdPartyAnnotationsAndLinks() throws {
        let url = try makeFixture(pageCount: 2, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        let page = try XCTUnwrap(document.page(at: 0))

        let square = PDFAnnotation(
            bounds: CGRect(x: 300, y: 600, width: 80, height: 40),
            forType: .square,
            withProperties: nil
        )
        square.color = .systemRed
        page.addAnnotation(square)

        let note = PDFAnnotation(
            bounds: CGRect(x: 400, y: 620, width: 24, height: 24),
            forType: .text,
            withProperties: nil
        )
        note.contents = "existing note"
        page.addAnnotation(note)

        let link = PDFAnnotation(
            bounds: CGRect(x: 72, y: 500, width: 120, height: 20),
            forType: .link,
            withProperties: nil
        )
        link.action = PDFActionURL(url: URL(string: "https://example.com/yopdf")!)
        page.addAnnotation(link)

        try addMarkup(
            .highlight,
            to: model,
            selection: try selection(in: document, pageIndex: 0, from: 0, to: 10)
        )
        let highlight = try firstMarkup(on: 0, in: model)
        try selectMarkup(highlight, in: model)
        XCTAssertTrue(model.recolorSelectedMarkup(to: MarkupColorPalette.color(fromHex: "34C759")))
        XCTAssertTrue(model.convertSelectedMarkup())

        XCTAssertEqual(model.save(), .saved)

        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let annotations = try XCTUnwrap(reopened.page(at: 0)?.annotations)
        XCTAssertEqual(annotations.filter { $0.type?.hasSuffix("Square") == true }.count, 1)
        XCTAssertEqual(annotations.filter { $0.type?.hasSuffix("Text") == true }.count, 1)
        XCTAssertEqual(annotations.filter { $0.type?.hasSuffix("Link") == true }.count, 1)
        XCTAssertEqual(annotations.filter(\.isMarkup).count, 1)
        XCTAssertTrue(try XCTUnwrap(annotations.first(where: \.isMarkup)).isMarkupType("Underline"))
        XCTAssertEqual(
            try XCTUnwrap(annotations.first { $0.type?.hasSuffix("Text") == true }).contents,
            "existing note"
        )
        let reopenedLink = try XCTUnwrap(annotations.first { $0.type?.hasSuffix("Link") == true })
        let action = try XCTUnwrap(reopenedLink.action as? PDFActionURL)
        XCTAssertEqual(action.url?.absoluteString, "https://example.com/yopdf")
    }

    func testSuccessfulSaveKeepsUndoAndSelectionWithLiveDocument() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        try addMarkup(
            .highlight,
            to: model,
            selection: try selection(in: document, pageIndex: 0, from: 0, to: 10)
        )
        let annotation = try firstMarkup(on: 0, in: model)
        try selectMarkup(annotation, in: model)
        let documentBeforeSave = try XCTUnwrap(model.document)

        XCTAssertEqual(model.save(), .saved)

        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertTrue(model.canUndoMarkup, "an in-place save keeps the undo history")
        XCTAssertFalse(model.canRedoMarkup)
        XCTAssertNotNil(model.selectedMarkup)
        XCTAssertTrue(model.document === documentBeforeSave)
        XCTAssertEqual(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).count, 1)
        XCTAssertEqual(PDFDocument(url: url)?.page(at: 0)?.annotations.filter(\.isMarkup).count, 1)

        // The persisted /QuadPoints are relative to the annotation in the file
        // too, so hit-testing must still find the mark after the save.
        let reloaded = try firstMarkup(on: 0, in: model)
        try selectMarkup(reloaded, in: model)
        XCTAssertEqual(model.selectedMarkup?.kind, .highlight)
        model.clearMarkupSelection()
    }

    func testRecolourSurvivesSaveAndReopenWithOpaqueColour() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        try addMarkup(
            .highlight,
            to: model,
            selection: try selection(in: document, pageIndex: 0, from: 0, to: 10)
        )
        let annotation = try firstMarkup(on: 0, in: model)
        try selectMarkup(annotation, in: model)
        let custom = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.5)
        XCTAssertTrue(model.recolorSelectedMarkup(to: custom))

        XCTAssertEqual(model.save(), .saved)

        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let saved = try XCTUnwrap(reopened.page(at: 0)?.annotations.first(where: \.isMarkup))
        XCTAssertTrue(saved.isMarkupType("Highlight"))
        XCTAssertEqual(hex(saved.color), "3366CC")
        let rgb = try XCTUnwrap(saved.color.usingColorSpace(.sRGB))
        XCTAssertEqual(rgb.alphaComponent, 1.0, accuracy: 0.01)
        XCTAssertEqual(saved.quadrilateralPoints?.count, annotation.quadrilateralPoints?.count)
    }

    func testFailedSaveRetainsHistorySelectionAndAnnotations() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        try addMarkup(
            .highlight,
            to: model,
            selection: try selection(in: document, pageIndex: 0, from: 0, to: 10)
        )
        let annotation = try firstMarkup(on: 0, in: model)
        try selectMarkup(annotation, in: model)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

        let outcome = model.save()
        guard case .failed = outcome else {
            return XCTFail("expected a failed save, got \(outcome)")
        }
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.canUndoMarkup)
        XCTAssertNotNil(model.selectedMarkup)
        XCTAssertEqual(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).count, 1)
        XCTAssertTrue(model.document === document)
    }

    func testConflictRetainsHistoryAndSelection() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 3)
        let model = makeModel()
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        try addMarkup(
            .highlight,
            to: model,
            selection: try selection(in: document, pageIndex: 0, from: 0, to: 10)
        )
        let annotation = try firstMarkup(on: 0, in: model)
        try selectMarkup(annotation, in: model)
        let replacement = try PDFFixtureFactory.makeParagraphData(pageCount: 1, linesPerPage: 2)
        try replacement.write(to: url, options: .atomic)

        let outcome = model.save()
        guard case .conflict = outcome else {
            return XCTFail("expected a conflict, got \(outcome)")
        }
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.canUndoMarkup)
        XCTAssertNotNil(model.selectedMarkup)
        XCTAssertEqual(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).count, 1)
    }

    func testSaveAsClearsHistoryAndTheCopyBecomesTheEditableDocument() throws {
        let original = try makeFixture(pageCount: 1, linesPerPage: 3, named: "original")
        let copy = original.deletingLastPathComponent().appendingPathComponent("copy.pdf")
        temporaryFiles.append(copy)

        let model = makeModel()
        XCTAssertTrue(model.open(url: original))
        let document = try XCTUnwrap(model.document)
        try addMarkup(
            .highlight,
            to: model,
            selection: try selection(in: document, pageIndex: 0, from: 0, to: 10)
        )
        let highlight = try firstMarkup(on: 0, in: model)
        try selectMarkup(highlight, in: model)

        XCTAssertEqual(model.saveAs(to: copy), .saved)
        XCTAssertEqual(model.fileURL, copy)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.canUndoMarkup)
        XCTAssertNil(model.selectedMarkup)
        XCTAssertEqual(PDFDocument(url: copy)?.page(at: 0)?.annotations.filter(\.isMarkup).count, 1)
        XCTAssertEqual(PDFDocument(url: original)?.page(at: 0)?.annotations.filter(\.isMarkup).count, 0)

        // The new history starts at the copy: undoing the underline leaves the
        // saved highlight untouched.
        try addMarkup(
            .underline,
            to: model,
            selection: try selection(in: model.document!, pageIndex: 0, from: 12, to: 20)
        )
        XCTAssertTrue(model.undoMarkup())
        XCTAssertEqual(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).count, 1)
        XCTAssertFalse(model.canUndoMarkup)
        XCTAssertTrue(model.document?.page(at: 0)?.annotations.filter(\.isMarkup).first?.isMarkupType("Highlight") ?? false)
    }

    func testAbandonAndOpenClearTheHistory() throws {
        let first = try makeFixture(pageCount: 1, linesPerPage: 3, named: "first")
        let second = try makeFixture(pageCount: 1, linesPerPage: 3, named: "second")
        let model = makeModel()
        XCTAssertTrue(model.open(url: first))
        let document = try XCTUnwrap(model.document)
        try addMarkup(
            .highlight,
            to: model,
            selection: try selection(in: document, pageIndex: 0, from: 0, to: 10)
        )
        XCTAssertTrue(model.canUndoMarkup)

        model.abandonUnsavedChanges()
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.canUndoMarkup)
        XCTAssertFalse(model.canRedoMarkup)
        XCTAssertNil(model.selectedMarkup)

        XCTAssertTrue(model.open(url: second))
        XCTAssertFalse(model.canUndoMarkup)
        XCTAssertNil(model.selectedMarkup)
    }

    func testModelsHaveIndependentHistoriesAndDefaults() throws {
        let first = try makeFixture(pageCount: 1, linesPerPage: 3, named: "first")
        let second = try makeFixture(pageCount: 1, linesPerPage: 3, named: "second")
        let modelA = makeModel()
        let modelB = makeModel()
        XCTAssertTrue(modelA.open(url: first))
        XCTAssertTrue(modelB.open(url: second))

        XCTAssertTrue(modelA.setDefaultMarkupColor(MarkupColorPalette.color(fromHex: "34C759"), for: .highlight))
        XCTAssertTrue(modelB.setDefaultMarkupColor(MarkupColorPalette.color(fromHex: "FF2D55"), for: .highlight))

        try addMarkup(
            .highlight,
            to: modelA,
            selection: try selection(in: modelA.document!, pageIndex: 0, from: 0, to: 8)
        )
        try addMarkup(
            .highlight,
            to: modelB,
            selection: try selection(in: modelB.document!, pageIndex: 0, from: 0, to: 8)
        )
        XCTAssertEqual(hex(try firstMarkup(on: 0, in: modelA).color), "34C759")
        XCTAssertEqual(hex(try firstMarkup(on: 0, in: modelB).color), "FF2D55")

        XCTAssertTrue(modelA.undoMarkup())
        XCTAssertTrue(modelA.document?.page(at: 0)?.annotations.filter(\.isMarkup).isEmpty ?? false)
        XCTAssertEqual(modelB.document?.page(at: 0)?.annotations.filter(\.isMarkup).count, 1)
        XCTAssertTrue(modelB.canUndoMarkup)
    }
}

private extension PDFAnnotation {
    var isMarkup: Bool {
        type?.hasSuffix("Highlight") == true || type?.hasSuffix("Underline") == true
    }

    func isMarkupType(_ name: String) -> Bool {
        type?.hasSuffix(name) == true
    }
}
