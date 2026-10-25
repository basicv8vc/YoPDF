import Foundation

/// Per-window, in-memory state that should survive rebuilding the sidebar but
/// should be discarded when the reader opens a different PDF.
public struct ReaderNavigationMemory: Equatable, Sendable {
    public private(set) var documentGeneration: Int?
    public private(set) var selectedOutlineItemID: String?
    public private(set) var outlineExpansionOverrides: [String: Bool] = [:]
    public private(set) var hasLoadedOutline = false
    public private(set) var indexedAnnotationRevision: Int?

    public init() {}

    /// Returns true only when the memory belongs to a different document.
    @discardableResult
    public mutating func prepare(for generation: Int) -> Bool {
        guard documentGeneration != generation else { return false }
        documentGeneration = generation
        selectedOutlineItemID = nil
        outlineExpansionOverrides = [:]
        hasLoadedOutline = false
        indexedAnnotationRevision = nil
        return true
    }

    public mutating func selectOutlineItem(_ id: String?) {
        selectedOutlineItemID = id
    }

    public mutating func setOutlineItem(_ id: String, expanded: Bool) {
        outlineExpansionOverrides[id] = expanded
    }

    public func isExpanded(for id: String, defaultValue: Bool) -> Bool {
        outlineExpansionOverrides[id] ?? defaultValue
    }

    public mutating func markOutlineLoaded() {
        hasLoadedOutline = true
    }

    public var needsOutlineLoad: Bool {
        !hasLoadedOutline
    }

    public func needsAnnotationIndex(for revision: Int) -> Bool {
        indexedAnnotationRevision != revision
    }

    public var hasAnnotationIndex: Bool {
        indexedAnnotationRevision != nil
    }

    public mutating func markAnnotationIndexUpdated(revision: Int) {
        indexedAnnotationRevision = revision
    }
}
