import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

@MainActor
final class ShuaCompatibilityTests: XCTestCase {

    private static let shuaStickerStyleKey = PDFAnnotationKey(rawValue: "ShuaStickerStyle")
    private static let shuaThoughtMetadataKey = PDFAnnotationKey(rawValue: "ShuaThoughtMetadata")
    private static let yoPDFShuaAnchorKey = PDFAnnotationKey(rawValue: "/YoPDFShuaAnchorID")

    nonisolated(unsafe) private var temporaryFiles: [URL] = []

    private struct Region: Codable {
        let pageIndex: Int
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private struct Point: Codable {
        let x: Double
        let y: Double
    }

    private struct AnchorMetadata: Codable {
        let id: UUID
        let excerpt: String
        let regions: [Region]
        let isPageLevel: Bool
        let markerPosition: Point?
    }

    /// Mirrors ShuaMac's private `EmbeddedThoughtMetadata` Codable shape.
    private struct ThoughtMetadata: Codable {
        let version: Int
        let anchor: AnchorMetadata
        let thoughtID: UUID
        let thoughtOrder: Int
        let createdAt: Date
        let modifiedAt: Date
    }

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
            let directory = url.deletingLastPathComponent()
            if directory.lastPathComponent.hasPrefix("YoPDFTests-") {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    private func makeFixture(named name: String) throws -> URL {
        let data = try PDFFixtureFactory.makeParagraphData(pageCount: 1, linesPerPage: 3)
        let url = try PDFFixtureFactory.writeTemporaryFile(named: "\(name).pdf", contents: data)
        temporaryFiles.append(url)
        return url
    }

    private func openModel(at url: URL) -> PDFDocumentModel {
        let model = PDFDocumentModel(access: SecurityScopeSpy())
        XCTAssertTrue(model.open(url: url))
        return model
    }

    private func write(_ document: PDFDocument, to url: URL) throws {
        let data = try XCTUnwrap(NoteService.dataRepresentationPreservingShuaGroups(in: document))
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    private func addShuaThought(
        to page: PDFPage,
        anchorID: UUID,
        thoughtID: UUID = UUID(),
        order: Int,
        x: CGFloat,
        y: CGFloat,
        contents: String,
        includesName: Bool = true,
        style: NoteStickerStyle = NoteStickerStyle(motif: .cat, palette: .honey)
    ) throws -> PDFAnnotation {
        let note = PDFAnnotation(
            bounds: CGRect(x: x, y: y, width: 20, height: 20),
            forType: .text,
            withProperties: nil
        )
        note.iconType = .comment
        note.contents = contents
        note.userName = "Shua"
        note.color = style.palette.color
        let annotationName = "shua-thought:\(anchorID.uuidString):\(thoughtID.uuidString)"
        if includesName {
            XCTAssertTrue(note.setValue(annotationName, forAnnotationKey: .name))
        }
        let styleData = try JSONEncoder().encode(style)
        note.setValue(
            try XCTUnwrap(String(data: styleData, encoding: .utf8)),
            forAnnotationKey: Self.shuaStickerStyleKey
        )
        let metadata = ThoughtMetadata(
            version: 1,
            anchor: AnchorMetadata(
                id: anchorID,
                excerpt: "Mooncake architecture",
                regions: [Region(pageIndex: 0, x: 90, y: 360, width: 160, height: 22)],
                isPageLevel: false,
                markerPosition: Point(x: 0.5, y: 0.5)
            ),
            thoughtID: thoughtID,
            thoughtOrder: order,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let metadataData = try JSONEncoder().encode(metadata)
        note.setValue(
            try XCTUnwrap(String(data: metadataData, encoding: .utf8)),
            forAnnotationKey: Self.shuaThoughtMetadataKey
        )
        page.addAnnotation(note)
        return note
    }

    private func textAnnotations(on page: PDFPage) -> [PDFAnnotation] {
        page.annotations.filter { NoteService.isTextAnnotation($0) }
    }

    func testOneThreeAndTenThoughtsProduceOneCountedMarkerPerAnchor() throws {
        let url = try makeFixture(named: "shua-groups")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let groups: [(count: Int, x: CGFloat, y: CGFloat)] = [
            (1, 110, 680),
            (3, 300, 680),
            (10, 500, 680),
        ]

        for (groupIndex, group) in groups.enumerated() {
            let anchorID = UUID()
            for order in 0..<group.count {
                try addShuaThought(
                    to: page,
                    anchorID: anchorID,
                    order: order,
                    x: group.x,
                    y: group.y - CGFloat(order * 23),
                    contents: "Group \(groupIndex + 1), thought \(order + 1)"
                )
            }
        }
        try write(document, to: url)

        let markers = NoteService.markers(in: document)
        XCTAssertEqual(markers.count, 3)
        XCTAssertEqual(markers.map(\.count).sorted(), [1, 3, 10])
        XCTAssertTrue(markers.allSatisfy(\.showsCountBadge))
        XCTAssertEqual(markers.first(where: { $0.count == 3 })?.threadContents, [
            "Group 2, thought 1", "Group 2, thought 2", "Group 2, thought 3",
        ])

        let model = openModel(at: url)
        let modelPage = try XCTUnwrap(model.document?.page(at: 0))
        let tenThoughts = try XCTUnwrap(model.noteMarkers.first(where: { $0.count == 10 }))
        let hiddenIconBounds = try XCTUnwrap(tenThoughts.sourceHitBounds.last)
        let hiddenIconPoint = CGPoint(x: hiddenIconBounds.midX, y: hiddenIconBounds.midY)
        XCTAssertFalse(tenThoughts.bounds.contains(hiddenIconPoint))
        let selection = try XCTUnwrap(model.noteSelection(at: hiddenIconPoint, on: modelPage))
        XCTAssertTrue(selection.usesStickerPresentation)
        XCTAssertEqual(selection.groupCount, 10)
        XCTAssertEqual(selection.threadContents.count, 10)

        let threeThoughts = try XCTUnwrap(model.noteMarkers.first(where: { $0.count == 3 }))
        let neighboringHiddenIcon = try XCTUnwrap(threeThoughts.sourceHitBounds.last)
        let neighboringSelection = try XCTUnwrap(model.noteSelection(
            at: CGPoint(x: neighboringHiddenIcon.midX, y: neighboringHiddenIcon.midY),
            on: modelPage
        ))
        XCTAssertEqual(neighboringSelection.groupCount, 3)
        XCTAssertEqual(neighboringSelection.threadContents.first, "Group 2, thought 1")

        let singleThought = try XCTUnwrap(model.noteMarkers.first(where: { $0.count == 1 }))
        let singleSelection = try XCTUnwrap(model.noteSelection(at: singleThought.center, on: modelPage))
        XCTAssertEqual(singleSelection.groupCount, 1)
    }

    func testShuaMetadataAndGroupIdentitySurvivePDFKitSerialization() throws {
        let url = try makeFixture(named: "shua-round-trip")
        let source = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(source.page(at: 0))
        let anchorID = UUID()
        let thoughtIDs = (0..<3).map { _ in UUID() }
        for order in thoughtIDs.indices {
            try addShuaThought(
                to: page,
                anchorID: anchorID,
                thoughtID: thoughtIDs[order],
                order: order,
                x: 300,
                y: 650 - CGFloat(order * 23),
                contents: "Round-trip thought \(order + 1)"
            )
        }

        let data = try XCTUnwrap(NoteService.dataRepresentationPreservingShuaGroups(in: source))
        XCTAssertTrue(
            textAnnotations(on: page).allSatisfy {
                $0.value(forAnnotationKey: Self.yoPDFShuaAnchorKey) == nil
            },
            "temporary YoPDF grouping metadata is removed from the live document after serialization"
        )

        let reopened = try XCTUnwrap(PDFDocument(data: data))
        let reopenedPage = try XCTUnwrap(reopened.page(at: 0))
        let reopenedNotes = textAnnotations(on: reopenedPage)
        XCTAssertEqual(reopenedNotes.count, 3)
        XCTAssertEqual(NoteService.markers(in: reopened).map(\.count), [3])

        let metadata = try reopenedNotes.map { annotation -> ThoughtMetadata in
            let raw = try XCTUnwrap(
                annotation.value(forAnnotationKey: Self.shuaThoughtMetadataKey) as? String,
                "Shua's embedded recovery metadata must survive PDFKit serialization"
            )
            return try JSONDecoder().decode(ThoughtMetadata.self, from: Data(raw.utf8))
        }.sorted { $0.thoughtOrder < $1.thoughtOrder }
        XCTAssertEqual(metadata.map(\.anchor.id), Array(repeating: anchorID, count: 3))
        XCTAssertEqual(metadata.map(\.thoughtID), thoughtIDs)
        XCTAssertEqual(metadata.map(\.thoughtOrder), [0, 1, 2])
    }

    func testShuaMetadataAloneRestoresGroupAndThoughtOrder() throws {
        let url = try makeFixture(named: "shua-metadata-only")
        let source = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(source.page(at: 0))
        let anchorID = UUID()
        let orderToY: [CGFloat] = [610, 690, 650]
        for order in orderToY.indices {
            try addShuaThought(
                to: page,
                anchorID: anchorID,
                order: order,
                x: 320,
                y: orderToY[order],
                contents: "Metadata order \(order)",
                includesName: false
            )
        }

        let sourceNotes = textAnnotations(on: page)
        XCTAssertEqual(sourceNotes.count, 3)
        XCTAssertTrue(sourceNotes.allSatisfy { $0.value(forAnnotationKey: .name) == nil })
        XCTAssertTrue(sourceNotes.allSatisfy { $0.value(forAnnotationKey: Self.yoPDFShuaAnchorKey) == nil })
        let sourceMarker = try XCTUnwrap(NoteService.markers(in: source).first)
        XCTAssertEqual(sourceMarker.count, 3)
        XCTAssertEqual(sourceMarker.threadContents, [
            "Metadata order 0", "Metadata order 1", "Metadata order 2",
        ])

        try write(source, to: url)
        XCTAssertTrue(sourceNotes.allSatisfy { $0.value(forAnnotationKey: Self.yoPDFShuaAnchorKey) == nil })
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let reopenedNotes = textAnnotations(on: try XCTUnwrap(reopened.page(at: 0)))
        XCTAssertTrue(reopenedNotes.allSatisfy { $0.value(forAnnotationKey: .name) == nil })
        XCTAssertTrue(reopenedNotes.allSatisfy { $0.value(forAnnotationKey: Self.yoPDFShuaAnchorKey) == nil })
        let reopenedMarker = try XCTUnwrap(NoteService.markers(in: reopened).first)
        XCTAssertEqual(NoteService.markers(in: reopened).count, 1)
        XCTAssertEqual(reopenedMarker.count, 3)
        XCTAssertEqual(reopenedMarker.threadContents, [
            "Metadata order 0", "Metadata order 1", "Metadata order 2",
        ])
    }

    func testMalformedOrUnsupportedShuaMetadataDoesNotCreateAGroup() throws {
        let malformedValues = [
            "not-json",
            #"{"version":2,"anchor":{"id":"\#(UUID().uuidString)"},"thoughtID":"\#(UUID().uuidString)","thoughtOrder":0}"#,
            #"{"version":1,"anchor":{"id":"\#(UUID().uuidString)"},"thoughtID":"\#(UUID().uuidString)","thoughtOrder":-1}"#,
        ]
        for raw in malformedValues {
            let note = PDFAnnotation(
                bounds: CGRect(x: 100, y: 100, width: 20, height: 20),
                forType: .text,
                withProperties: nil
            )
            XCTAssertTrue(note.setValue(raw, forAnnotationKey: Self.shuaThoughtMetadataKey))
            XCTAssertNil(NoteService.shuaAnchorID(of: note))
            XCTAssertFalse(NoteService.isShuaThought(note))
        }
    }

    func testExternalShuaStyleWinsAndPartialStyleKeepsYoPDFTemplateFields() throws {
        let url = try makeFixture(named: "shua-external-style")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        _ = try addShuaThought(
            to: page,
            anchorID: UUID(),
            order: 0,
            x: 300,
            y: 600,
            contents: "Style source of truth"
        )
        let annotation = try XCTUnwrap(textAnnotations(on: page).first)
        let yopdfStyle = NoteStickerStyle(
            motif: .washi,
            palette: .rose,
            title: "YoPDF template",
            symbol: "quote.opening"
        )
        let externalStyle = NoteStickerStyle(
            motif: .star,
            palette: .sky,
            title: "Shua edit",
            symbol: "sparkles"
        )
        annotation.setValue(yopdfStyle.serialized, forAnnotationKey: PDFAnnotationKey(rawValue: "/YoPDFNoteStyle"))
        annotation.setValue(
            try XCTUnwrap(String(data: JSONEncoder().encode(externalStyle), encoding: .utf8)),
            forAnnotationKey: Self.shuaStickerStyleKey
        )
        XCTAssertEqual(NoteService.style(of: annotation), externalStyle)

        // A Shua style can omit template-only fields. Keep those from YoPDF
        // while still taking the motif and palette from ShuaMac's current key.
        let partialShuaStyle = #"{"palette":"mint","motif":"flower"}"#
        annotation.setValue(partialShuaStyle, forAnnotationKey: Self.shuaStickerStyleKey)
        XCTAssertEqual(
            NoteService.style(of: annotation),
            NoteStickerStyle(
                motif: .flower,
                palette: .mint,
                title: yopdfStyle.title,
                symbol: yopdfStyle.symbol
            )
        )

        annotation.setValue(#"{"palette":"unknown"}"#, forAnnotationKey: Self.shuaStickerStyleKey)
        XCTAssertEqual(NoteService.style(of: annotation), yopdfStyle)
    }

    func testRestylingShuaThoughtUpdatesBothFormatsAndUndoRedoRoundTrips() throws {
        let url = try makeFixture(named: "shua-style-edit")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let anchorID = UUID()
        let originalStyle = NoteStickerStyle(motif: .cat, palette: .honey)
        _ = try addShuaThought(
            to: page,
            anchorID: anchorID,
            order: 0,
            x: 300,
            y: 600,
            contents: "Keep this thought",
            style: originalStyle
        )
        try write(document, to: url)

        let model = openModel(at: url)
        let marker = try XCTUnwrap(model.noteMarkers.first)
        XCTAssertEqual(marker.style, originalStyle)
        let modelPage = try XCTUnwrap(model.document?.page(at: 0))
        let selection = try XCTUnwrap(model.noteSelection(at: marker.center, on: modelPage))
        let changedStyle = NoteStickerStyle(
            motif: .washi,
            palette: .rose,
            title: "Reading note",
            symbol: "quote.opening"
        )

        guard case let .success(updated) = model.updateNote(
            selection,
            contents: selection.contents,
            style: changedStyle
        ) else {
            return XCTFail("the imported Shua thought should accept an explicit style edit")
        }
        XCTAssertEqual(updated.style, changedStyle)
        let editedAnnotation = try XCTUnwrap(textAnnotations(on: modelPage).first)
        let editedShuaJSON = try XCTUnwrap(
            editedAnnotation.value(forAnnotationKey: Self.shuaStickerStyleKey) as? String
        )
        XCTAssertEqual(NoteStickerStyle(serialized: editedShuaJSON), changedStyle)
        XCTAssertNil(
            (try XCTUnwrap(JSONSerialization.jsonObject(with: Data(editedShuaJSON.utf8))) as? [String: Any])?["v"],
            "ShuaMac's Codable style format is unversioned"
        )

        XCTAssertTrue(model.undoMarkup())
        let undone = try XCTUnwrap(textAnnotations(on: modelPage).first)
        XCTAssertEqual(NoteService.style(of: undone), originalStyle)
        XCTAssertEqual(
            NoteStickerStyle(serialized: try XCTUnwrap(
                undone.value(forAnnotationKey: Self.shuaStickerStyleKey) as? String
            )),
            originalStyle
        )

        XCTAssertTrue(model.redoMarkup())
        let redone = try XCTUnwrap(textAnnotations(on: modelPage).first)
        XCTAssertEqual(NoteService.style(of: redone), changedStyle)
        XCTAssertEqual(model.save(), .saved)

        let reopened = openModel(at: url)
        let persisted = try XCTUnwrap(reopened.noteMarkers.first)
        XCTAssertEqual(persisted.style, changedStyle)
        XCTAssertEqual(persisted.count, 1)
        let persistedNote = try XCTUnwrap(textAnnotations(on: try XCTUnwrap(reopened.document?.page(at: 0))).first)
        XCTAssertEqual(
            NoteStickerStyle(serialized: try XCTUnwrap(
                persistedNote.value(forAnnotationKey: Self.shuaStickerStyleKey) as? String
            )),
            changedStyle
        )
        let persistedMetadata = try XCTUnwrap(
            persistedNote.value(forAnnotationKey: Self.shuaThoughtMetadataKey) as? String
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ThoughtMetadata.self, from: Data(persistedMetadata.utf8)).anchor.id,
            anchorID
        )
    }
}
