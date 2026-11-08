import Foundation

/// The identity and ordering of a window's research tabs.
///
/// Runtime PDF models, security-scoped sessions, and views live outside this
/// value. Each P0-A tab has one PDF pane; `paneID` gives that pane a stable
/// identity for the later split-layout phase.
public struct WorkspaceTabIdentity: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let paneID: UUID

    public init(id: UUID = UUID(), paneID: UUID = UUID()) {
        self.id = id
        self.paneID = paneID
    }
}

/// Direction of the terminal-style tab navigation shortcuts: `⇧⌘[` moves
/// left and `⇧⌘]` moves right.
public enum WorkspaceTabDirection: Sendable {
    case previous
    case next
}

/// Pure tab-order and selection state for one application window.
public struct WorkspaceState: Equatable, Sendable {
    public private(set) var tabs: [WorkspaceTabIdentity]
    public private(set) var activeTabID: UUID?

    public init(initialTab: WorkspaceTabIdentity = WorkspaceTabIdentity()) {
        tabs = [initialTab]
        activeTabID = initialTab.id
    }

    public var activePaneID: UUID? {
        tabs.first(where: { $0.id == activeTabID })?.paneID
    }

    @discardableResult
    public mutating func insert(_ tab: WorkspaceTabIdentity, activate: Bool = true) -> Bool {
        guard !tabs.contains(where: { $0.id == tab.id || $0.paneID == tab.paneID }) else {
            return false
        }
        tabs.append(tab)
        if activate || activeTabID == nil { activeTabID = tab.id }
        return true
    }

    @discardableResult
    public mutating func activate(tabID: UUID) -> Bool {
        guard tabs.contains(where: { $0.id == tabID }) else { return false }
        activeTabID = tabID
        return true
    }

    /// Selects the neighbouring tab in `direction`, wrapping at both ends the
    /// way browsers and coding terminals do: previous on the leftmost tab
    /// selects the rightmost one, and next on the rightmost selects the
    /// leftmost. With one tab this is a harmless no-op, so holding the shortcut
    /// down (key repeat) can never produce an out-of-range lookup.
    ///
    /// Returns the newly selected tab ID, or `nil` if the workspace has no
    /// valid selection.
    @discardableResult
    public mutating func activateAdjacentTab(direction: WorkspaceTabDirection) -> UUID? {
        guard let currentTabID = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == currentTabID })
        else { return nil }

        let step = direction == .previous ? -1 : 1
        activeTabID = tabs[(index + step + tabs.count) % tabs.count].id
        return activeTabID
    }

    /// Reorders the tab strip, which is how the user drags a PDF tab into a new
    /// horizontal position.
    ///
    /// `insertionIndex` counts slots in the tab strip *after* the moved tab has
    /// been taken out, which is what an insertion marker drawn between the
    /// remaining tabs reports. Passing the moved tab's own index is therefore a
    /// no-op rather than an off-by-one slide. Out-of-range values are clamped
    /// so a drag that ends past either end of the strip still lands on the
    /// first or last slot instead of being rejected.
    ///
    /// Selection is carried by tab identity, so the active PDF keeps rendering
    /// while its neighbours change places around it. Returns `false` only when
    /// `tabID` is not part of this workspace.
    @discardableResult
    public mutating func move(tabID: UUID, toInsertionIndex insertionIndex: Int) -> Bool {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == tabID }) else {
            return false
        }

        let moved = tabs.remove(at: currentIndex)
        tabs.insert(moved, at: min(max(insertionIndex, 0), tabs.count))
        return true
    }

    /// Slides one tab a single slot toward `direction`, wrapping at both ends.
    ///
    /// Menu-bar commands and a tab's context menu use this instead of a drag,
    /// so they share the drag's ordering rule. Because `move` counts slots in
    /// the strip with the moved tab removed, moving right inserts at
    /// `index + 1` and moving left inserts at `index - 1`. Wrapping sends the
    /// leftmost tab to the last slot and the rightmost tab to the first, so a
    /// held-down shortcut keeps cycling instead of stalling at an edge.
    @discardableResult
    public mutating func move(tabID: UUID, direction: WorkspaceTabDirection) -> Bool {
        guard tabs.count > 1,
              let index = tabs.firstIndex(where: { $0.id == tabID })
        else { return false }

        let insertionIndex: Int
        switch direction {
        case .previous:
            insertionIndex = index == 0 ? tabs.count - 1 : index - 1
        case .next:
            insertionIndex = index == tabs.count - 1 ? 0 : index + 1
        }
        return move(tabID: tabID, toInsertionIndex: insertionIndex)
    }

    /// Moves the tab whose PDF is currently visible. Menu-bar commands act on
    /// the focused window's selection; the context menu instead passes the tab
    /// the user right-clicked, which need not be the active one.
    @discardableResult
    public mutating func moveActiveTab(direction: WorkspaceTabDirection) -> Bool {
        guard let activeTabID else { return false }
        return move(tabID: activeTabID, direction: direction)
    }

    /// Removes a tab while keeping one window tab alive and selecting a valid
    /// neighbor when the active tab is closed.
    @discardableResult
    public mutating func close(tabID: UUID) -> WorkspaceTabIdentity? {
        guard tabs.count > 1,
              let index = tabs.firstIndex(where: { $0.id == tabID })
        else { return nil }

        let removed = tabs.remove(at: index)
        if activeTabID == tabID {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        return removed
    }

    public func contains(tabID: UUID) -> Bool {
        tabs.contains(where: { $0.id == tabID })
    }
}
