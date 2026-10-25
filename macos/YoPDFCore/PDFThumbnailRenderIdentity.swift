import Foundation

/// Inputs that affect the rendered pixels for one sidebar page thumbnail.
///
/// A SwiftUI thumbnail cell may keep its local image state when a different
/// document reuses the same page index. Include every render input in the task
/// identity so stale images are hidden and regenerated when any input changes.
public struct PDFThumbnailRenderIdentity: Hashable, Sendable {
    public let loadGeneration: Int
    public let annotationRevision: Int
    public let pageIndex: Int
    public let thumbnailSize: CGSize

    public init(
        loadGeneration: Int,
        annotationRevision: Int,
        pageIndex: Int,
        thumbnailSize: CGSize
    ) {
        self.loadGeneration = loadGeneration
        self.annotationRevision = annotationRevision
        self.pageIndex = pageIndex
        self.thumbnailSize = thumbnailSize
    }
}
