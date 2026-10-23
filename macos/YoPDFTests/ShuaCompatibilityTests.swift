import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

@MainActor
final class ShuaCompatibilityTests: XCTestCase {

    private static let shuaStickerStyleKey = PDFAnnotationKey(rawValue: "ShuaStickerStyle")
    private static let shuaThoughtMetadataKey = PDFAnnotationKey(rawValue: "ShuaThoughtMetadata")
    private static let yoPDFShuaIdentityKey = PDFAnnotationKey(rawValue: "/YoPDFShuaThoughtIdentity")
    private static let yoPDFShuaAnchorKey = PDFAnnotationKey(rawValue: "/YoPDFShuaAnchorID")

    nonisolated(unsafe) private var temporaryFiles: [URL] = []

    private struct Region: Codable {
        let pageIndex: Int
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private struct Point: Codable, Equatable {
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
        excerpt: String = "Mooncake architecture",
        isPageLevel: Bool = false,
        includesName: Bool = true,
        markerPosition: Point = Point(x: 0.5, y: 0.5),
        size: CGFloat = 20,
        style: NoteStickerStyle = NoteStickerStyle(motif: .cat, palette: .honey)
    ) throws -> PDFAnnotation {
        let note = PDFAnnotation(
            bounds: CGRect(x: x, y: y, width: size, height: size),
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
                excerpt: excerpt,
                regions: [Region(pageIndex: 0, x: 90, y: 360, width: 160, height: 22)],
                isPageLevel: isPageLevel,
                markerPosition: markerPosition
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

    private func markerPosition(in annotation: PDFAnnotation) throws -> Point {
        let raw = try XCTUnwrap(
            annotation.value(forAnnotationKey: Self.shuaThoughtMetadataKey) as? String
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        )
        let anchor = try XCTUnwrap(payload["anchor"] as? [String: Any])
        let position = try XCTUnwrap(anchor["markerPosition"] as? [String: Any])
        let x = try XCTUnwrap(position["x"] as? NSNumber).doubleValue
        let y = try XCTUnwrap(position["y"] as? NSNumber).doubleValue
        return Point(x: x, y: y)
    }

    private func replaceEmbeddedMetadata(
        on annotation: PDFAnnotation,
        anchorID: UUID? = nil,
        thoughtID: UUID? = nil
    ) throws {
        let raw = try XCTUnwrap(
            annotation.value(forAnnotationKey: Self.shuaThoughtMetadataKey) as? String
        )
        let old = try JSONDecoder().decode(ThoughtMetadata.self, from: Data(raw.utf8))
        let metadata = ThoughtMetadata(
            version: old.version,
            anchor: AnchorMetadata(
                id: anchorID ?? old.anchor.id,
                excerpt: old.anchor.excerpt,
                regions: old.anchor.regions,
                isPageLevel: old.anchor.isPageLevel,
                markerPosition: old.anchor.markerPosition
            ),
            thoughtID: thoughtID ?? old.thoughtID,
            thoughtOrder: old.thoughtOrder,
            createdAt: old.createdAt,
            modifiedAt: old.modifiedAt
        )
        let data = try JSONEncoder().encode(metadata)
        XCTAssertTrue(annotation.setValue(
            try XCTUnwrap(String(data: data, encoding: .utf8)),
            forAnnotationKey: Self.shuaThoughtMetadataKey
        ))
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
            let cropBox = page.bounds(for: .cropBox)
            let markerPosition = Point(
                x: Double((group.x + 10 - cropBox.minX) / cropBox.width),
                y: Double((group.y + 20 - cropBox.minY) / cropBox.height)
            )
            for order in 0..<group.count {
                try addShuaThought(
                    to: page,
                    anchorID: anchorID,
                    order: order,
                    x: group.x,
                    y: group.y - CGFloat(order * 23),
                    contents: "Group \(groupIndex + 1), thought \(order + 1)",
                    markerPosition: markerPosition
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
        let cropBox = page.bounds(for: .cropBox)
        XCTAssertEqual(sourceMarker.center.x, cropBox.minX + cropBox.width / 2, accuracy: 0.001)
        XCTAssertEqual(sourceMarker.center.y, cropBox.minY + cropBox.height / 2, accuracy: 0.001)

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
        XCTAssertEqual(reopenedMarker.center.x, sourceMarker.center.x, accuracy: 0.001)
        XCTAssertEqual(reopenedMarker.center.y, sourceMarker.center.y, accuracy: 0.001)
    }

    func testMetadataFreeLegacyStacksRecognize20And24PointRectsAfterSerialization() throws {
        let url = try makeFixture(named: "shua-legacy-stack-sizes")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))

        for (groupIndex, size) in [CGFloat(20), CGFloat(24)].enumerated() {
            let anchorID = UUID()
            for order in 0..<3 {
                let note = try addShuaThought(
                    to: page,
                    anchorID: anchorID,
                    order: order,
                    x: CGFloat(120 + groupIndex * 250),
                    y: CGFloat(650 - order * 23),
                    contents: "Legacy \(Int(size))pt thought \(order)",
                    size: size
                )
                note.removeValue(forAnnotationKey: .name)
                note.removeValue(forAnnotationKey: Self.shuaThoughtMetadataKey)
            }
        }

        XCTAssertEqual(NoteService.markers(in: document).map(\.count).sorted(), [3, 3])
        try write(document, to: url)

        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(NoteService.markers(in: reopened).map(\.count).sorted(), [3, 3])
    }

    func testMovingShuaGroupSyncsMetadataAcrossUndoRedoAndSaveReopen() throws {
        let url = try makeFixture(named: "shua-move-metadata")
        let source = try XCTUnwrap(PDFDocument(url: url))
        let sourcePage = try XCTUnwrap(source.page(at: 0))
        let anchorID = UUID()
        for order in 0..<3 {
            _ = try addShuaThought(
                to: sourcePage,
                anchorID: anchorID,
                order: order,
                x: 300,
                y: CGFloat(650 - order * 23),
                contents: "Move thought \(order)"
            )
        }

        let sourceNotes = textAnnotations(on: sourcePage)
        let extendedNote = try XCTUnwrap(sourceNotes.first)
        let originalRaw = try XCTUnwrap(
            extendedNote.value(forAnnotationKey: Self.shuaThoughtMetadataKey) as? String
        )
        var originalPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(originalRaw.utf8)) as? [String: Any]
        )
        originalPayload["futureTopLevelField"] = ["preserve": true]
        var originalAnchor = try XCTUnwrap(originalPayload["anchor"] as? [String: Any])
        originalAnchor["futureAnchorField"] = "keep this value"
        originalPayload["anchor"] = originalAnchor
        let extendedMetadata = try JSONSerialization.data(withJSONObject: originalPayload)
        XCTAssertTrue(extendedNote.setValue(
            try XCTUnwrap(String(data: extendedMetadata, encoding: .utf8)),
            forAnnotationKey: Self.shuaThoughtMetadataKey
        ))
        let originalPosition = try markerPosition(in: extendedNote)
        try write(source, to: url)

        let model = openModel(at: url)
        let marker = try XCTUnwrap(model.noteMarkers.first)
        let modelPage = try XCTUnwrap(model.document?.page(at: 0))
        let selection = try XCTUnwrap(model.noteSelection(at: marker.center, on: modelPage))
        let target = CGPoint(x: marker.bounds.midX + 70, y: marker.bounds.midY + 45)
        XCTAssertTrue(model.moveNoteMarker(selection, to: target))

        let crop = modelPage.bounds(for: .cropBox)
        let expectedPosition = Point(
            x: Double((target.x - crop.minX) / crop.width),
            y: Double((target.y - crop.minY) / crop.height)
        )
        let movedNotes = textAnnotations(on: modelPage)
        XCTAssertEqual(movedNotes.count, 3)
        for note in movedNotes {
            let position = try markerPosition(in: note)
            XCTAssertEqual(position.x, expectedPosition.x, accuracy: 0.000001)
            XCTAssertEqual(position.y, expectedPosition.y, accuracy: 0.000001)
        }

        let movedExtendedNote = try XCTUnwrap(
            movedNotes.first { $0.contents == extendedNote.contents }
        )
        let movedPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(
                try XCTUnwrap(movedExtendedNote.value(forAnnotationKey: Self.shuaThoughtMetadataKey) as? String).utf8
            )) as? [String: Any]
        )
        XCTAssertEqual(
            (movedPayload["futureTopLevelField"] as? [String: Bool])?["preserve"],
            true
        )
        XCTAssertEqual(
            (movedPayload["anchor"] as? [String: Any])?["futureAnchorField"] as? String,
            "keep this value"
        )

        XCTAssertTrue(model.undoMarkup())
        let restoredMarker = try XCTUnwrap(model.noteMarkers.first)
        XCTAssertEqual(restoredMarker.bounds.midX, marker.bounds.midX, accuracy: 0.001)
        XCTAssertEqual(restoredMarker.bounds.midY, marker.bounds.midY, accuracy: 0.001)
        for note in textAnnotations(on: modelPage) {
            let position = try markerPosition(in: note)
            XCTAssertEqual(position.x, originalPosition.x, accuracy: 0.000001)
            XCTAssertEqual(position.y, originalPosition.y, accuracy: 0.000001)
        }

        XCTAssertTrue(model.redoMarkup())
        let redoneMarker = try XCTUnwrap(model.noteMarkers.first)
        XCTAssertEqual(redoneMarker.bounds.midX, target.x, accuracy: 0.001)
        XCTAssertEqual(redoneMarker.bounds.midY, target.y, accuracy: 0.001)
        XCTAssertEqual(model.save(), .saved)

        let reopened = openModel(at: url)
        let reopenedMarker = try XCTUnwrap(reopened.noteMarkers.first)
        XCTAssertEqual(reopenedMarker.count, 3)
        XCTAssertEqual(reopenedMarker.bounds.midX, target.x, accuracy: 0.001)
        XCTAssertEqual(reopenedMarker.bounds.midY, target.y, accuracy: 0.001)
        let reopenedPage = try XCTUnwrap(reopened.document?.page(at: 0))
        for note in textAnnotations(on: reopenedPage) {
            let position = try markerPosition(in: note)
            XCTAssertEqual(position.x, expectedPosition.x, accuracy: 0.000001)
            XCTAssertEqual(position.y, expectedPosition.y, accuracy: 0.000001)
        }
    }

    func testMovingShuaGroupKeepsEveryNoteInsideCropBoxAtAllPageEdges() throws {
        let url = try makeFixture(named: "shua-move-boundaries")
        let source = try XCTUnwrap(PDFDocument(url: url))
        let sourcePage = try XCTUnwrap(source.page(at: 0))
        let anchorID = UUID()
        for order in 0..<4 {
            _ = try addShuaThought(
                to: sourcePage,
                anchorID: anchorID,
                order: order,
                x: 300,
                y: CGFloat(650 - order * 23),
                contents: "Boundary thought \(order)"
            )
        }
        try write(source, to: url)

        let model = openModel(at: url)
        let marker = try XCTUnwrap(model.noteMarkers.first)
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let selection = try XCTUnwrap(model.noteSelection(at: marker.center, on: page))
        let crop = page.bounds(for: .cropBox)
        let edgeTargets = [
            CGPoint(x: crop.minX - 200, y: crop.minY - 200),
            CGPoint(x: crop.maxX + 200, y: crop.minY - 200),
            CGPoint(x: crop.minX - 200, y: crop.maxY + 200),
            CGPoint(x: crop.maxX + 200, y: crop.maxY + 200),
        ]

        for target in edgeTargets {
            XCTAssertTrue(model.moveNoteMarker(selection, to: target))
            let currentMarker = try XCTUnwrap(model.noteMarkers.first)
            XCTAssertTrue(crop.contains(currentMarker.bounds), "sticker remains inside the CropBox")
            for note in textAnnotations(on: page) {
                XCTAssertTrue(
                    crop.insetBy(dx: -0.001, dy: -0.001).contains(note.bounds),
                    "thought rectangle remains inside the CropBox: \(note.bounds)"
                )
            }
        }

        XCTAssertEqual(model.save(), .saved)
        let reopened = openModel(at: url)
        let reopenedPage = try XCTUnwrap(reopened.document?.page(at: 0))
        let reopenedCrop = reopenedPage.bounds(for: .cropBox)
        XCTAssertTrue(reopenedCrop.contains(try XCTUnwrap(reopened.noteMarkers.first).bounds))
        for note in textAnnotations(on: reopenedPage) {
            XCTAssertTrue(
                reopenedCrop.insetBy(dx: -0.001, dy: -0.001).contains(note.bounds),
                "saved thought rectangle remains inside the CropBox: \(note.bounds)"
            )
        }
    }

    func testShuaEmbeddedAnchorRetainsQuoteAndPageLevelContext() throws {
        let url = try makeFixture(named: "shua-anchor-context")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let textNote = try addShuaThought(
            to: page,
            anchorID: UUID(),
            order: 0,
            x: 300,
            y: 600,
            contents: "Text anchored",
            includesName: false
        )
        let pageNote = try addShuaThought(
            to: page,
            anchorID: UUID(),
            order: 0,
            x: 400,
            y: 600,
            contents: "Page anchored",
            excerpt: "",
            isPageLevel: true,
            includesName: false
        )

        XCTAssertEqual(NoteService.excerpt(of: textNote), "Mooncake architecture")
        XCTAssertFalse(NoteService.isPageLevel(textNote))
        XCTAssertNil(NoteService.excerpt(of: pageNote))
        XCTAssertTrue(NoteService.isPageLevel(pageNote))
    }

    func testConflictingShuaNameAndEmbeddedIdentityDoNotMergeThoughts() throws {
        let url = try makeFixture(named: "shua-conflicting-identity")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let nameAnchorID = UUID()
        let metadataAnchorID = UUID()
        let thoughtID = UUID()
        let conflicted = try addShuaThought(
            to: page,
            anchorID: nameAnchorID,
            thoughtID: thoughtID,
            order: 0,
            x: 300,
            y: 600,
            contents: "Conflicting identity"
        )
        let rawMetadata = try XCTUnwrap(
            conflicted.value(forAnnotationKey: Self.shuaThoughtMetadataKey) as? String
        )
        let oldMetadata = try JSONDecoder().decode(ThoughtMetadata.self, from: Data(rawMetadata.utf8))
        let conflictingMetadata = ThoughtMetadata(
            version: oldMetadata.version,
            anchor: AnchorMetadata(
                id: metadataAnchorID,
                excerpt: oldMetadata.anchor.excerpt,
                regions: oldMetadata.anchor.regions,
                isPageLevel: oldMetadata.anchor.isPageLevel,
                markerPosition: oldMetadata.anchor.markerPosition
            ),
            thoughtID: thoughtID,
            thoughtOrder: oldMetadata.thoughtOrder,
            createdAt: oldMetadata.createdAt,
            modifiedAt: oldMetadata.modifiedAt
        )
        let conflictingData = try JSONEncoder().encode(conflictingMetadata)
        XCTAssertTrue(conflicted.setValue(
            try XCTUnwrap(String(data: conflictingData, encoding: .utf8)),
            forAnnotationKey: Self.shuaThoughtMetadataKey
        ))
        _ = try addShuaThought(
            to: page,
            anchorID: metadataAnchorID,
            order: 1,
            x: 300,
            y: 577,
            contents: "Other thought",
            includesName: false
        )

        XCTAssertNil(NoteService.shuaAnchorID(of: conflicted))
        XCTAssertEqual(NoteService.markers(in: document).map(\.count).sorted(), [1, 1])
    }

    func testConflictingYoPDFAnchorCacheDoesNotJoinShuaGroup() throws {
        let url = try makeFixture(named: "shua-conflicting-yopdf-anchor")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let anchorID = UUID()
        let note = try addShuaThought(
            to: page,
            anchorID: anchorID,
            order: 0,
            x: 300,
            y: 600,
            contents: "Embedded identity",
            includesName: false
        )
        XCTAssertTrue(note.setValue(UUID().uuidString, forAnnotationKey: Self.yoPDFShuaAnchorKey))

        XCTAssertNil(NoteService.shuaAnchorID(of: note))
        XCTAssertEqual(NoteService.markers(in: document).map(\.count), [1])
    }

    func testConflictingThoughtIdentitySurvivesPDFKitRoundTrip() throws {
        let url = try makeFixture(named: "shua-conflicting-thought-round-trip")
        let source = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(source.page(at: 0))
        let anchorID = UUID()
        let namedThoughtID = UUID()
        let embeddedThoughtID = UUID()
        let conflicted = try addShuaThought(
            to: page,
            anchorID: anchorID,
            thoughtID: namedThoughtID,
            order: 0,
            x: 300,
            y: 600,
            contents: "Conflicted identity"
        )
        try replaceEmbeddedMetadata(on: conflicted, thoughtID: embeddedThoughtID)
        _ = try addShuaThought(
            to: page,
            anchorID: anchorID,
            thoughtID: UUID(),
            order: 1,
            x: 300,
            y: 577,
            contents: "Same anchor sibling",
            includesName: false
        )

        XCTAssertNil(NoteService.shuaAnchorID(of: conflicted))
        XCTAssertEqual(NoteService.markers(in: source).map(\.count).sorted(), [1, 1])

        let data = try XCTUnwrap(NoteService.dataRepresentationPreservingShuaGroups(in: source))
        XCTAssertNil(conflicted.value(forAnnotationKey: Self.yoPDFShuaIdentityKey))
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        let reopenedPage = try XCTUnwrap(reopened.page(at: 0))
        let reopenedNotes = textAnnotations(on: reopenedPage)
        let reopenedConflict = try XCTUnwrap(
            reopenedNotes.first { $0.contents == "Conflicted identity" }
        )

        XCTAssertNil(reopenedConflict.value(forAnnotationKey: .name), "PDFKit drops `/NM` in this round trip")
        XCTAssertEqual(
            reopenedConflict.value(forAnnotationKey: Self.yoPDFShuaIdentityKey) as? String,
            "\(anchorID.uuidString):\(namedThoughtID.uuidString)"
        )
        XCTAssertNil(NoteService.shuaAnchorID(of: reopenedConflict))
        XCTAssertEqual(NoteService.markers(in: reopened).map(\.count).sorted(), [1, 1])
    }

    func testRestyledShuaThoughtWithConflictingIdentityProducesOneMarker() throws {
        let url = try makeFixture(named: "shua-restyled-conflicting-identity")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let anchorID = UUID()
        let note = try addShuaThought(
            to: page,
            anchorID: anchorID,
            order: 0,
            x: 300,
            y: 600,
            contents: "Restyled conflicting thought"
        )

        NoteService.setStyle(NoteStickerStyle(motif: .shiba, palette: .mint), on: note)
        try replaceEmbeddedMetadata(on: note, thoughtID: UUID())

        XCTAssertTrue(NoteService.isYoPDFNote(note))
        XCTAssertTrue(NoteService.isShuaThought(note))
        XCTAssertNil(NoteService.shuaAnchorID(of: note))
        let markers = NoteService.markers(in: document)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.count, 1)
        XCTAssertEqual(markers.first?.showsCountBadge, true)
        XCTAssertEqual(markers.first?.threadContents, ["Restyled conflicting thought"])
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
