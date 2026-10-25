import Foundation
import PDFKit

/// Converts the standard PDF annotations in one document into a portable
/// Markdown reading log. Annotation text is plain text in the PDF, so Markdown
/// punctuation is escaped to keep it from changing the document structure.
@MainActor
public enum AnnotationMarkdownExporter {

    /// Returns the document title and all supported annotations, grouped by
    /// their 1-based page number in PDF order.
    public static func markdown(for document: PDFDocument, fallbackTitle: String) -> String {
        let documentTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = oneLine(documentTitle.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle)

        var pageSections: [String] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let entries = page.annotations.compactMap { annotation in
                markdown(for: annotation, on: page)
            }
            guard !entries.isEmpty else { continue }
            pageSections.append("## Page \(pageIndex + 1)\n\n" + entries.joined(separator: "\n\n"))
        }

        let heading = "# \(escapeMarkdown(title))"
        guard !pageSections.isEmpty else { return heading }
        return heading + "\n\n" + pageSections.joined(separator: "\n\n")
    }

    private static func markdown(for annotation: PDFAnnotation, on page: PDFPage) -> String? {
        if let kind = MarkupKind(annotation: annotation) {
            var blocks: [String] = []
            if let quote = selectedText(for: annotation, on: page) {
                if kind == .underline {
                    blocks.append("**Underline**")
                }
                blocks.append(blockquote(quote))
            }
            if let comment = nonempty(annotation.contents) {
                blocks.append(noteBlock(comment))
            }
            return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
        }

        guard NoteService.isTextAnnotation(annotation) else { return nil }

        var blocks: [String] = []
        if let excerpt = NoteService.excerpt(of: annotation) {
            blocks.append(blockquote(excerpt))
        }
        if let contents = nonempty(annotation.contents) {
            blocks.append(noteBlock(contents))
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    /// Reads each painted quad separately so unrelated text between disjoint
    /// lines or columns is not pulled in by the annotation's bounding box.
    private static func selectedText(for annotation: PDFAnnotation, on page: PDFPage) -> String? {
        let lines = MarkupGeometry.quadRects(for: annotation).compactMap { rect -> String? in
            guard let text = page.selection(for: rect)?.string else { return nil }
            let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return normalized.isEmpty ? nil : normalized
        }
        let joined = lines.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func blockquote(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { line in
                line.isEmpty ? ">" : "> \(escapeMarkdown(line))"
            }
            .joined(separator: "\n")
    }

    private static func noteBlock(_ text: String) -> String {
        "💡 Note:\n\n\(escapeMarkdown(text))"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func oneLine(_ value: String) -> String {
        value.components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Notes and extracted PDF text are plain text. Escaping Markdown syntax
    /// preserves that meaning and prevents annotation contents from creating
    /// headings, links, images, or HTML in the exported file.
    private static func escapeMarkdown(_ text: String) -> String {
        let markdownPunctuation = Set("\\`*_{}[]<>()#+-.!|")
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            if markdownPunctuation.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
