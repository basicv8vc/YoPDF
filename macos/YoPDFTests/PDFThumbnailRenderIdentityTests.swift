import XCTest
@testable import YoPDFCore

final class PDFThumbnailRenderIdentityTests: XCTestCase {

    func testSwitchingPDFInTheSameWindowInvalidatesPageThumbnail() {
        let firstDocument = identity(loadGeneration: 1)
        let secondDocument = identity(loadGeneration: 2)

        XCTAssertNotEqual(firstDocument, secondDocument)
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
        loadGeneration: Int = 1,
        annotationRevision: Int = 0,
        pageIndex: Int = 0,
        thumbnailSize: CGSize = CGSize(width: 180, height: 234)
    ) -> PDFThumbnailRenderIdentity {
        PDFThumbnailRenderIdentity(
            loadGeneration: loadGeneration,
            annotationRevision: annotationRevision,
            pageIndex: pageIndex,
            thumbnailSize: thumbnailSize
        )
    }
}
