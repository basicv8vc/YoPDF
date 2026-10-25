import Foundation

/// Normalizes the subtype name PDFKit reports for a PDF annotation.
///
/// PDFKit can return either `Text` or `/Text` depending on how the annotation
/// was read. Consumers should compare the normalized name rather than relying
/// on one representation.
public enum PDFAnnotationTypeName {

    public static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.drop(while: { $0 == "/" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return name.lowercased()
    }

    /// Whether an annotation is an implementation detail or navigation link
    /// that should not appear as a user-created annotation in the sidebar.
    public static func isExcludedFromAnnotationSidebar(_ rawValue: String?) -> Bool {
        guard let type = normalized(rawValue) else { return false }
        return type == "popup" || type == "widget" || type == "link"
    }
}
