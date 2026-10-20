import Foundation
import PDFKit

/// Owns one opened PDF document and the reader's navigation/zoom state.
///
/// Deliberately free of UI and of any network, account, or agent concern:
/// the model can be exercised in unit tests without a window or a running app.
@MainActor
public final class PDFDocumentModel: ObservableObject {

    public enum LoadError: Error, Equatable {
        case notAFileURL
        case unsupportedType(String)
        case fileMissing
        case unreadable
        case emptyDocument
    }

    public static let minimumZoomScale: CGFloat = 0.25
    public static let maximumZoomScale: CGFloat = 5.0

    private static let zoomStep: CGFloat = 1.25

    @Published public private(set) var document: PDFDocument?
    @Published public private(set) var fileURL: URL?
    @Published public private(set) var title: String = ""
    @Published public private(set) var pageCount: Int = 0
    @Published public private(set) var currentPageIndex: Int = 0
    /// The zoom the user asked for. Only meaningful while `isAutoScaling` is false.
    @Published public private(set) var zoomScale: CGFloat = 1
    /// What the view is actually showing. Mirrored from PDFView so that the
    /// first manual zoom starts from the fitted scale instead of jumping to 100%.
    @Published public private(set) var effectiveScale: CGFloat = 1
    @Published public private(set) var isAutoScaling: Bool = true
    @Published public private(set) var lastError: LoadError?
    /// Bumped on every successful open so the view can re-apply layout.
    @Published public private(set) var loadGeneration: Int = 0

    /// PDFKit memory-maps the file, so a security-scoped URL must stay open for
    /// as long as the document is displayed. Non-sandboxed builds return false
    /// here and need no bookkeeping.
    private var securityScopedURL: URL?

    public init() {}

    public var isLoaded: Bool { document != nil }

    /// 1-based page number for display; 0 when nothing is open.
    public var displayPageNumber: Int { pageCount == 0 ? 0 : currentPageIndex + 1 }

    // MARK: - Opening

    /// Opens a local PDF. Returns `false` and records `lastError` on failure;
    /// a failed open never replaces the document that is already loaded.
    @discardableResult
    public func open(url: URL) -> Bool {
        guard url.isFileURL else {
            lastError = .notAFileURL
            return false
        }
        guard url.pathExtension.lowercased() == "pdf" else {
            lastError = .unsupportedType(url.pathExtension)
            return false
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = .fileMissing
            return false
        }

        beginSecurityScope(for: url)
        guard let opened = PDFDocument(url: url) else {
            endSecurityScope()
            lastError = .unreadable
            return false
        }
        guard opened.pageCount > 0 else {
            endSecurityScope()
            lastError = .emptyDocument
            return false
        }

        apply(document: opened, fileURL: url)
        return true
    }

    public func close() {
        endSecurityScope()
        document = nil
        fileURL = nil
        title = ""
        pageCount = 0
        currentPageIndex = 0
        zoomScale = 1
        effectiveScale = 1
        isAutoScaling = true
        lastError = nil
        loadGeneration &+= 1
    }

    public func dismissError() {
        lastError = nil
    }

    private func apply(document: PDFDocument, fileURL: URL?) {
        self.document = document
        self.fileURL = fileURL
        pageCount = document.pageCount
        currentPageIndex = 0
        zoomScale = 1
        effectiveScale = 1
        isAutoScaling = true
        lastError = nil
        title = Self.resolvedTitle(for: document, fileURL: fileURL)
        loadGeneration &+= 1
    }

    private func beginSecurityScope(for url: URL) {
        endSecurityScope()
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
    }

    private func endSecurityScope() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    private static func resolvedTitle(for document: PDFDocument, fileURL: URL?) -> String {
        if let raw = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let name = fileURL?.deletingPathExtension().lastPathComponent, !name.isEmpty {
            return name
        }
        return "Untitled"
    }

    // MARK: - Navigation

    public func goToPage(_ index: Int) {
        guard pageCount > 0 else { return }
        currentPageIndex = min(max(index, 0), pageCount - 1)
    }

    public func goToNextPage() {
        goToPage(currentPageIndex + 1)
    }

    public func goToPreviousPage() {
        goToPage(currentPageIndex - 1)
    }

    // MARK: - Zoom

    public func setZoomScale(_ scale: CGFloat) {
        guard scale.isFinite else { return }
        zoomScale = min(max(scale, Self.minimumZoomScale), Self.maximumZoomScale)
        effectiveScale = zoomScale
        isAutoScaling = false
    }

    /// Base for the next zoom step: the live fitted scale while auto-scaling,
    /// otherwise the user's chosen scale.
    private var zoomBase: CGFloat {
        isAutoScaling ? effectiveScale : zoomScale
    }

    public func zoomIn() {
        setZoomScale(zoomBase * Self.zoomStep)
    }

    public func zoomOut() {
        setZoomScale(zoomBase / Self.zoomStep)
    }

    public func resetZoom() {
        setZoomScale(1)
    }

    public func fitToWindow() {
        isAutoScaling = true
    }

    /// Called by the view whenever PDFView's scale changes. Never flips
    /// `isAutoScaling`: the view is the only source of truth while fitting.
    public func updateEffectiveScale(_ scale: CGFloat) {
        guard scale.isFinite, scale > 0 else { return }
        effectiveScale = scale
        if !isAutoScaling {
            zoomScale = min(max(scale, Self.minimumZoomScale), Self.maximumZoomScale)
        }
    }

    public func setAutoScaling(_ enabled: Bool) {
        isAutoScaling = enabled
    }
}

extension PDFDocumentModel.LoadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAFileURL:
            return "That location is not a local file."
        case let .unsupportedType(ext):
            let suffix = ext.isEmpty ? "no file extension" : ".\(ext)"
            return "YoPDF can only open PDF files, but this file has \(suffix)."
        case .fileMissing:
            return "The file could not be found. It may have been moved or deleted."
        case .unreadable:
            return "This file is not a readable PDF. It may be damaged or password protected."
        case .emptyDocument:
            return "This PDF contains no pages."
        }
    }
}
