import Foundation
import PDFKit

/// Inputs that affect the rendered pixels for one sidebar page thumbnail.
///
/// A SwiftUI thumbnail cell may keep its local image state when a different
/// document reuses the same page index. Include every render input in the task
/// identity so stale images are hidden and regenerated when any input changes.
/// The document identifier is part of that set: two tabs each load their own
/// `PDFDocumentModel`, so both can sit at `loadGeneration == 1` and equal
/// annotation revisions while showing entirely different files.
public struct PDFThumbnailRenderIdentity: Hashable, Sendable {
    public let documentIdentifier: ObjectIdentifier
    public let loadGeneration: Int
    public let annotationRevision: Int
    public let pageIndex: Int
    public let thumbnailSize: CGSize

    public init(
        document: PDFDocument,
        loadGeneration: Int,
        annotationRevision: Int,
        pageIndex: Int,
        thumbnailSize: CGSize
    ) {
        self.documentIdentifier = ObjectIdentifier(document)
        self.loadGeneration = loadGeneration
        self.annotationRevision = annotationRevision
        self.pageIndex = pageIndex
        self.thumbnailSize = thumbnailSize
    }
}
