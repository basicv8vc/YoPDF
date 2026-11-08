import PDFKit
import XCTest
@testable import YoPDFCore

final class PDFThumbnailRenderIdentityTests: XCTestCase {

    func testSwitchingPDFInTheSameWindowInvalidatesPageThumbnail() {
        // The same PDFDocument instance reloaded: only the generation moved.
        let document = PDFDocument()
        let firstDocument = identity(document: document, loadGeneration: 1)
        let secondDocument = identity(document: document, loadGeneration: 2)

        XCTAssertNotEqual(firstDocument, secondDocument)
    }

    /// The reported bug: each tab loads its own model once, so both sit at
    /// `loadGeneration == 1` and revision 0 while showing different files.
    /// Only the document identity can tell the two thumbnails apart.
    func testSwitchingToADocumentAtTheSameLoadGenerationInvalidatesThumbnail() {
        let firstDocument = PDFDocument()
        let secondDocument = PDFDocument()

        let first = identity(document: firstDocument, loadGeneration: 1)
        let second = identity(document: secondDocument, loadGeneration: 1)

        XCTAssertNotEqual(first, second)
    }

    func testReloadingTheSameDocumentKeepsIdentityStableUnlessGenerationMoves() {
        let document = PDFDocument()

        XCTAssertEqual(
            identity(document: document, loadGeneration: 1),
            identity(document: document, loadGeneration: 1)
        )
    }

    func testAddingAnnotationInvalidatesPageThumbnail() {
        // Same document instance: only the annotation revision moved.
        let document = PDFDocument()
        let beforeAnnotation = identity(document: document, annotationRevision: 4)
        let afterAnnotation = identity(document: document, annotationRevision: 5)

        XCTAssertNotEqual(beforeAnnotation, afterAnnotation)
    }

    func testThumbnailIdentityIncludesPageIndexAndSize() {
        // Same document instance: only pageIndex / thumbnailSize moved.
        let document = PDFDocument()
        let original = identity(document: document)

        XCTAssertNotEqual(original, identity(document: document, pageIndex: 1))
        XCTAssertNotEqual(
            original,
            identity(document: document, thumbnailSize: CGSize(width: 181, height: 234))
        )
    }

    /// Every caller must pass an explicit document so field-isolation tests can
    /// share one instance (only the field under test moves) while the
    /// cross-document test passes two distinct instances.
    private func identity(
        document: PDFDocument,
        loadGeneration: Int = 1,
        annotationRevision: Int = 0,
        pageIndex: Int = 0,
        thumbnailSize: CGSize = CGSize(width: 180, height: 234)
    ) -> PDFThumbnailRenderIdentity {
        PDFThumbnailRenderIdentity(
            document: document,
            loadGeneration: loadGeneration,
            annotationRevision: annotationRevision,
            pageIndex: pageIndex,
            thumbnailSize: thumbnailSize
        )
    }
}
