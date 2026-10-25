import Combine
import YoPDFCore

/// State shared by one reader window so hiding and recreating its sidebar does
/// not discard outline selection, expansion choices, or an existing index.
@MainActor
final class ReaderNavigationState: ObservableObject {
    @Published var annotationItems: [SidebarAnnotationItem] = []
    @Published var outlineItems: [OutlineSidebarItem] = []
    @Published private(set) var memory = ReaderNavigationMemory()

    @discardableResult
    func prepare(for generation: Int) -> Bool {
        var updatedMemory = memory
        guard updatedMemory.prepare(for: generation) else { return false }

        memory = updatedMemory
        outlineItems = []
        annotationItems = []
        return true
    }

    func updateMemory(_ update: (inout ReaderNavigationMemory) -> Void) {
        var updatedMemory = memory
        update(&updatedMemory)
        memory = updatedMemory
    }
}
