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
