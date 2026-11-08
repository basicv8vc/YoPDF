import PDFKit
import XCTest
@testable import YoPDFCore

final class PDFThumbnailRenderIdentityTests: XCTestCase {

    func testSwitchingPDFInTheSameWindowInvalidatesPageThumbnail() {
        let firstDocument = identity(loadGeneration: 1)
        let secondDocument = identity(loadGeneration: 2)

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
        let beforeAnnotation = identity(annotationRevision: 4)
        let afterAnnotation = identity(annotationRevision: 5)

        XCTAssertNotEqual(beforeAnnotation, afterAnnotation)
    }

    func testThumbnailIdentityIncludesPageIndexAndSize() {
        let original = identity()

        XCTAssertNotEqual(original, identity(pageIndex: 1))
        XCTAssertNotEqual(original, identity(thumbnailSize: CGSize(width: 181, height: 234)))
    }

    private func identity(
        document: PDFDocument = PDFDocument(),
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
