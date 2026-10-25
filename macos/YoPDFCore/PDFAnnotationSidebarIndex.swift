import PDFKit

/// One annotation row in document order as shown by the reader sidebar.
public struct PDFAnnotationSidebarEntry: Identifiable {
    public let id: String
    public let pageIndex: Int
    public let annotation: PDFAnnotation

    fileprivate init(id: String, pageIndex: Int, annotation: PDFAnnotation) {
        self.id = id
        self.pageIndex = pageIndex
        self.annotation = annotation
    }
}

/// Builds the annotation rows on demand when the reader's Annotations view is
/// first selected, and again when the document's annotation revision changes.
public enum PDFAnnotationSidebarIndex {

    @MainActor
    public static func entries(in document: PDFDocument) -> [PDFAnnotationSidebarEntry] {
        var result: [PDFAnnotationSidebarEntry] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            let visibleAnnotations = page.annotations.enumerated().filter { entry in
                !PDFAnnotationTypeName.isExcludedFromAnnotationSidebar(entry.element.type)
            }
            let sortedAnnotations = visibleAnnotations.sorted { left, right in
                let leftY = left.element.bounds.maxY
                let rightY = right.element.bounds.maxY
                let safeLeftY = leftY.isFinite ? leftY : 0
                let safeRightY = rightY.isFinite ? rightY : 0
                if safeLeftY != safeRightY { return safeLeftY > safeRightY }
                return left.offset < right.offset
            }

            for (index, entry) in sortedAnnotations.enumerated() {
                result.append(
                    PDFAnnotationSidebarEntry(
                        id: "\(pageIndex)-\(index)",
                        pageIndex: pageIndex,
                        annotation: entry.element
                    )
                )
            }
        }

        return result
    }
}
