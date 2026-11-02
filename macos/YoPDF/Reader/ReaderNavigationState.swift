import Combine
import YoPDFCore

/// One tab's sidebar state, retained while the user switches to another tab or
/// temporarily hides the sidebar.
@MainActor
final class ReaderNavigationState: ObservableObject {
    @Published var annotationItems: [SidebarAnnotationItem] = []
    @Published var outlineItems: [OutlineSidebarItem] = []
    @Published private(set) var memory = ReaderNavigationMemory()
    @Published var selectedSection: ReaderSidebarSection = .thumbnails
    @Published var isVisible = true

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
