import Foundation

/// Pure geometry behind the tab strip's live-reflow drag feedback.
///
/// A drag must not read the frames it is currently animating: shifting a tab
/// changes the layout, which changes the reported frames, which would change
/// the drop slot again and make the strip oscillate. The view therefore freezes
/// one measurement at the start of the drag and passes that snapshot here for
/// the rest of the gesture. Ordering itself is only committed on release via
/// `WorkspaceState.move(tabID:toInsertionIndex:)`.
///
/// This type deliberately has no SwiftUI or AppKit dependency so the placement
/// rules can be unit tested without a window.
public enum WorkspaceTabReflow {
    /// Horizontal extent of one tab in the strip's own coordinate space.
    public struct Slot: Equatable, Sendable {
        public let minX: Double
        public let width: Double

        public init(minX: Double, width: Double) {
            self.minX = minX
            self.width = width
        }

        public var midX: Double { minX + width / 2 }
        public var maxX: Double { minX + width }
    }

    /// Counts the other tabs whose midpoint the pointer has passed.
    ///
    /// The dragged tab is excluded, so the result is an insertion index in the
    /// strip *after* that tab has been taken out — the same unit
    /// `WorkspaceState.move(tabID:toInsertionIndex:)` expects.
    public static func insertionIndex(
        pointerX: Double,
        tabIDs: [UUID],
        slots: [UUID: Slot],
        draggingTabID: UUID
    ) -> Int {
        var passed = 0
        for tabID in tabIDs where tabID != draggingTabID {
            guard let slot = slots[tabID] else { continue }
            if pointerX > slot.midX { passed += 1 }
        }
        return passed
    }

    /// Horizontal offset each *other* tab needs in order to show the order the
    /// dragged tab would land in. The dragged tab is absent from the result;
    /// its own movement stays pinned to the pointer.
    ///
    /// Slots are laid out from the strip's leading edge by accumulating the
    /// measured widths, so tabs of different widths end up exactly where the
    /// real HStack will place them once the order is committed. That makes the
    /// release transition continuous instead of snapping. An incomplete
    /// measurement returns an empty map, which leaves every tab in place
    /// rather than shifting them to a guessed position.
    public static func offsets(
        tabIDs: [UUID],
        slots: [UUID: Slot],
        spacing: Double,
        draggingTabID: UUID,
        insertionIndex: Int
    ) -> [UUID: Double] {
        guard slots[draggingTabID] != nil else { return [:] }

        let others = tabIDs.filter { $0 != draggingTabID }
        let targetIndex = min(max(insertionIndex, 0), others.count)
        var order = others
        order.insert(draggingTabID, at: targetIndex)

        let leadingEdge = slots.values.map(\.minX).min() ?? 0
        var result: [UUID: Double] = [:]
        var x = leadingEdge
        for tabID in order {
            guard let slot = slots[tabID] else { return [:] }
            if tabID != draggingTabID {
                result[tabID] = x - slot.minX
            }
            x += slot.width + spacing
        }
        return result
    }
}
