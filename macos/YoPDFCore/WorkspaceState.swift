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
