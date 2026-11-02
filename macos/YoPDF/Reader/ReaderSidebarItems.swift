import PDFKit
import YoPDFCore

/// The three document-scoped views in the reader sidebar.
enum ReaderSidebarSection: String, CaseIterable, Identifiable {
    case outline
    case thumbnails
    case annotations

    var id: Self { self }

    var title: String {
        switch self {
        case .outline: "Outline"
        case .thumbnails: "Thumbnails"
        case .annotations: "Annotations"
        }
    }

    var symbolName: String {
        switch self {
        case .outline: "list.bullet.indent"
        case .thumbnails: "square.grid.2x2"
        case .annotations: "pencil.tip.crop.circle"
        }
    }
}

struct OutlineSidebarItem: Identifiable {
    static let maximumDepth = 48

    let id: String
    let outline: PDFOutline
    let title: String
    let depth: Int
    let childCount: Int
    let destination: PDFDestination?
    let destinationPageIndex: Int?
    var isExpanded: Bool

    var canExpand: Bool {
        childCount > 0 && depth < Self.maximumDepth
    }
}

struct SidebarAnnotationItem: Identifiable {
    let id: String
    let pageIndex: Int
    let annotation: PDFAnnotation

    var typeLabel: String {
        switch PDFAnnotationTypeName.normalized(annotation.type) {
        case "text": "Note"
        case "freetext": "Text"
        case "strikeout": "Strike Out"
        case "fileattachment": "Attachment"
        case let type?:
            type.prefix(1).uppercased() + String(type.dropFirst())
        default: "Annotation"
        }
    }

    var title: String {
        if PDFAnnotationTypeName.normalized(annotation.type) == "text",
           let contents = annotation.contents,
           let preview = Self.preview(contents) {
            return preview
        }
        return typeLabel
    }

    var iconName: String {
        switch PDFAnnotationTypeName.normalized(annotation.type) {
        case "highlight": "highlighter"
        case "underline": "underline"
        case "strikeout": "strikethrough"
        case "text": "note.text"
        case "freetext": "text.alignleft"
        case "square": "square"
        case "circle": "circle"
        case "stamp": "stamp"
        case "ink": "pencil.tip"
        default: "pencil.tip.crop.circle"
        }
    }

    private static func preview(_ contents: String) -> String? {
        let words = contents.prefix(400).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let normalized = words.joined(separator: " ")
        return String(normalized.prefix(96)) + (normalized.count > 96 ? "…" : "")
    }
}
