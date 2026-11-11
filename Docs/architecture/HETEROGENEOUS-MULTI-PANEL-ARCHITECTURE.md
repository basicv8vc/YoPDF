# YoPDF Heterogeneous Multi-Panel Research Workspace Architecture Contract

**Status**: Final Architecture Contract Revision (v2.1.0, Incorporating CTO Final Review)
**Document Version**: 2.1.0
**Target Platform**: macOS 14.0+ (Sonoma), Apple Silicon & Intel
**Author**: Senior macOS Architect, YoPDF Core Team
**Date**: November 2026
**Scope**: Architecture & Contract Specification (Non-Implementation)

---

## 1. Executive Summary

### 1.1 The Product Vision

YoPDF is evolving beyond a standalone PDF reader into a unified **Multi-Panel Research Workspace**.

> *"YoPDF is not a collection of separate tools inside a window. It is a workspace where heterogeneous content types—PDFs, research notes, reference figures, web literature, and autonomous agents—work together around a research task."*

In modern academic, scientific, and professional knowledge work, reading a PDF never happens in isolation. A researcher reads an empirical paper, cross-examines a cited methodology in a browser, excerpts key equations and diagrams into a structured Markdown paper note, inspects high-resolution microscopy or architecture figures, and consults an AI research agent to synthesize complex arguments. Today, users juggle multiple disconnected applications, continually losing mental context, copy-pasting unstructured text, and losing document provenance.

YoPDF solves this by providing a native, local-first, multi-panel workspace where heterogeneous panels collaborate seamlessly through typed research context, while preserving strict data ownership, offline capability, and native macOS fidelity.

### 1.2 Architectural Principles: The Three-Tier Model

To support heterogeneous panels without destabilizing YoPDF's existing rock-solid PDF foundation, the architecture establishes a strict **Three-Tier Decoupling Principle**:

```
+-----------------------------------------------------------------------------------+
|                                     WORKSPACE                                     |
|    Window Lifecycle | Tab Strip | Binary Split Layout Tree | Active Selection     |
+-----------------------------------------------------------------------------------+
                                          |
                      Hosts 1..N Visual Panes (Polymorphic)
                                          v
+-----------------------------------------------------------------------------------+
|                                       PANE                                        |
|  Stable PaneID | Visual Viewport State (Zoom/Page/Scroll) | Command Focus Adapter |
+-----------------------------------------------------------------------------------+
                                          |
                    References 1 Underlying Resource via Session
                                          v
+-----------------------------------------------------------------------------------+
|                                 RESOURCE / SESSION                                |
|   Canonical Identity | In-Memory Document Model | Persistence & File Leasing      |
+-----------------------------------------------------------------------------------+
```

1. **Workspace Tier**: Manages windows, tabs, layout geometry (binary split tree), active pane focus, and cross-pane action routing. It knows nothing about PDFKit, WKWebView, or Markdown text engines.
2. **Pane Tier**: A visual viewport region inside a split. It owns viewport-specific state (scroll offset, zoom scale, active page index, in-pane search state, note composer UI) and routes user commands to its underlying session. Multiple Panes can reference the **same** Resource.
3. **Resource / Session Tier**: Represents the authoritative runtime state and ownership of an opened resource (local PDF file, local Markdown note, local figure image, remote URL, or local Agent conversation). It owns file security scopes, data persistence, atomic staging, autosave debounce, search serialization, and modification dirty flags.

---

## 2. Current Architecture Audit: PDF Resource State vs. Pane View State

### 2.1 Audit of the Current Implementation

The current codebase contains tightly coupled abstractions that mix document identity with viewport presentation:

1. **`PDFDocumentModel` (`macos/YoPDFCore/PDFDocumentModel.swift`)**:
   - Currently acts as both the **document data model** (owning `PDFDocument`, annotations, `DocumentSession`, autosave debouncing, and undo stacks) and the **view controller** (owning `currentPageIndex`, `zoomScale`, `effectiveScale`, `isAutoScaling`, `currentSelection`, and `selectedMarkup`).
   - If two panes were created with two `PDFDocumentModel` instances pointing to the same file, they would acquire two independent file sessions, maintain divergent undo stacks, and risk data corruption during autosave.
2. **`WorkspaceTabSession` (`macos/YoPDF/App/WorkspaceWindowModel.swift`)**:
   - Tightly binds 1 Tab ID to 1 Pane ID, 1 `PDFDocumentModel`, 1 `NoteComposerStore`, 1 `PDFSearchSession`, and 1 `ReaderNavigationState`.
   - Assumes a strictly 1:1:1 tab-to-pane-to-document relationship.
3. **`PDFSearchSession` (`macos/YoPDFCore/PDFSearchSession.swift`)**:
   - Manages query strings, result lists, and active match navigation. It explicitly documents that a `PDFDocument` can have only **one active find operation at a time** (`PDFDocument.beginFindString`, `cancelFindString`).
   - If two panes search independently on the same `PDFDocument`, their operations will collide unless serialized.
4. **`ReaderNavigationState` (`macos/YoPDF/Reader/ReaderNavigationState.swift`)**:
   - Manages sidebar visibility (`isVisible`), selected section (`selectedSection`), and navigation memory (`ReaderNavigationMemory`). This is strictly pane-specific.
5. **`NoteComposerStore` (`macos/YoPDFCore/NoteDraftProtection.swift`)**:
   - Manages active note creation/editing popovers, modal presentation, and uncommitted draft protection. While its `Mode` captures logical page coordinates, its `anchorRect: CGRect` is currently expressed in local view space.
6. **`PDFViewerRepresentable` (`macos/YoPDF/Reader/PDFViewerRepresentable.swift`)**:
   - Bridges AppKit `PDFView` into SwiftUI, synchronizing scroll, zoom, selections, and popover anchors.

### 2.2 Separation of Responsibilities & PDFKit Search Concurrency

To enable multi-panel layouts (such as two panes displaying the same PDF at different pages and zoom levels), these responsibilities are strictly decoupled:

```
+-----------------------------------------------------------------------------------+
|                        SHARED PDF RESOURCE STATE (Model)                          |
|  - PDFDocument instance & underlying file identity (URL, DocumentVersion)         |
|  - Annotation collection & mutation history (markupUndoStack, markupRedoStack)    |
|  - Document dirty state (hasUnsavedChanges, editRevision)                         |
|  - Persistence & autosave debounce coordination (autoSaveTask, DocumentStore)     |
|  - Security-scoped file access lease (DocumentSession)                            |
|  - External change detection (checkExternalChange())                              |
|  - PDFSearchCoordinator (Serializes PDFKit find operations on PDFDocument)       |
+-----------------------------------------------------------------------------------+
                                          |
                        Observed by 1..N Independent Panes
                                          v
+---------------------------------------+   +---------------------------------------+
|          PDF PANE A STATE             |   |          PDF PANE B STATE             |
|  - Visible Page: Page 3               |   |  - Visible Page: Page 18              |
|  - Zoom Scale: 150% (Manual)          |   |  - Zoom Scale: Fit Width (Auto)       |
|  - Local Text Selection               |   |  - Local Text Selection               |
|  - Selected Markup in View            |   |  - Selected Markup in View            |
|  - In-Pane Search: "methodology"      |   |  - In-Pane Search: "appendix"         |
|  - Sidebar: Visible (Outline)         |   |  - Sidebar: Hidden                    |
|  - Active Note Composer (Local UI)    |   |  - Active Note Composer (Local UI)    |
+---------------------------------------+   +---------------------------------------+
```

#### PDFKit Search Concurrency Architecture

Because `PDFDocument` supports only one active find operation at a time, search responsibilities are split between the Pane and the Resource:

| Search Responsibility | Owner | Role & Implementation |
| :--- | :--- | :--- |
| **Search Query (`inputQuery`, `query`)** | `PDFPaneModel` | User input string for this specific pane. |
| **Current Result Index** | `PDFPaneModel` | Active highlight index in this pane's viewport. |
| **Find Bar Visibility** | `PDFPaneModel` | Local search UI visibility. |
| **Pane Search Generation** | `PDFPaneModel` | Monotonic counter incremented on query change. |
| **Active PDFKit Find Operation** | `PDFSearchCoordinator` | Calls `beginFindString` / `cancelFindString` on `PDFDocument`. |
| **Operation Serialization** | `PDFSearchCoordinator` | FIFO queue serializing queries across panes. |

**Search Concurrency Invariants**:
1. **Independent State**: Each pane retains its own query, match results (`results: [PDFSelection]`), and active result navigation index.
2. **Serialized Execution**: PDFKit operations against the shared `PDFDocument` are serialized through `PDFSearchCoordinator`. Only one PDFKit find task executes at a time on a given `PDFDocument`.
3. **No Cross-Pane Cancellation**: A new query in Pane A cancels or re-queues Pane A's operation, but does **not** cancel or corrupt Pane B's active results or pending request.
4. **Stale Result Rejection**: Asynchronous notifications (`PDFDocumentDidFindMatch`, `PDFDocumentDidEndFind`) carry a request identity and generation counter. Notifications from superseded requests are discarded.
5. **Resource Lifetime Invalidation**: Replacing or closing the shared PDF resource immediately cancels outstanding find operations and clears search queues.
6. **No Speculative Concurrency**: The design does not claim concurrent PDFKit find execution; it explicitly serializes access at the resource level.

### 2.3 Note Editing State and Anchor Stability Across Pane Movement

`NoteComposerStore` manages in-flight note composition:
- **Ownership**: The active `NoteComposerStore` belongs to the **visual Pane**, because the composer UI (popover or sheet) is positioned relative to that pane's view coordinates.
- **Uncommitted Draft Lifecycle**:
  - While the user is typing, the draft text exists in `NoteComposerStore.session`.
  - The draft publishes its dirty state (`hasUncommittedChanges`, `revision`) to the **Workspace / Window Close Guard** (`UnsavedWork`).
  - Closing a tab or quitting the application triggers the existing prompt: *"Save this note first?"* (`ReaderPromptPolicy`).
  - If the user switches tabs or moves panes, the draft remains attached to that Pane and is preserved.
- **Commit Boundary**:
  - When the user clicks "Save Note" (or approves saving during close), the draft is converted into a standard `/Text` `PDFAnnotation` and committed into the **Shared PDF Resource State**.
  - The shared resource records the annotation, pushes to `markupUndoStack`, marks `hasUnsavedChanges = true`, and schedules debounce autosave.

#### Making Note Anchors Stable Across Movement and Resizing

In the current implementation, `NoteComposerSession` stores `anchorRect: CGRect` in reader/view coordinates. When a pane is resized, moved between splits, or reparented in the layout tree, these view coordinates become invalid.

To guarantee stability, the architecture strictly decouples the **Persistent Logical Anchor** from the **Transient Presentation Anchor**:

```
+-----------------------------------------------------------------------------------+
| Persistent Logical Anchor (Stored in NoteDraft / NoteSelection)                   |
| - pageIndex: Int (0-based PDF page index)                                         |
| - bounds: CGRect (Marker rectangle in PDF page-space coordinates)                  |
| - targetAnnotationID: UUID? (ID of existing annotation if editing)                |
| - excerpt: String? (Captured text snippet at anchor creation)                     |
+-----------------------------------------------------------------------------------+
                                          |
        Dynamically converted by PageAnchorResolver on pane resize/move
                                          v
+-----------------------------------------------------------------------------------+
| Transient Presentation Anchor (Derived View State)                                |
| - anchorRect: CGRect (View coordinates in the active pane's coordinate system)    |
| - Recalculated via pdfView.convert(bounds, from: page)                            |
+-----------------------------------------------------------------------------------+
```

**Anchor Stability Invariants**:
1. `anchorRect` is a **derived presentation value**, never the sole source of anchor identity.
2. When a pane is resized, split, or reparented:
   - The uncommitted draft text, styling, and monotonic revision are preserved in `NoteComposerStore`.
   - The pane's `PageAnchorResolver` recalculates `anchorRect` from the persistent logical anchor (`pageIndex`, `bounds`).
   - The popover arrow seamlessly follows the note's page location in the updated layout.
3. If the referenced page or document anchor can no longer be resolved (e.g., page deleted externally or document replaced):
   - The draft text is **never** silently discarded.
   - The composer switches to a detached floating presentation with a status warning, allowing the user to copy or commit the text.

**Testing Strategy for Note Anchor Stability**:
- *Unit Test*: Verify that modifying pane bounds or simulating a window resize causes `PageAnchorResolver` to recompute `anchorRect` while `NoteDraft.bounds` and `NoteDraft.pageIndex` remain unchanged.
- *Reparenting Test*: Verify that moving a pane from a left split to a bottom split preserves an active uncommitted draft, its revision counter, and restores its popover anchor on the target page.

### 2.4 Explicit Property Migration Matrix

| Existing Type / Property | Current Owner | Proposed Owner | Migration Mechanism |
| :--- | :--- | :--- | :--- |
| `document: PDFDocument?` | `PDFDocumentModel` | `PDFResourceSession` | Move to ResourceSession. Shared across all panes viewing this document. |
| `fileURL: URL?` | `PDFDocumentModel` | `PDFResourceSession` | Move to ResourceSession. Canonical document location. |
| `title: String` | `PDFDocumentModel` | `PDFResourceSession` | Move to ResourceSession. Derived from document metadata or filename. |
| `pageCount: Int` | `PDFDocumentModel` | `PDFResourceSession` | Move to ResourceSession. Cached document page count. |
| `hasUnsavedChanges: Bool` | `PDFDocumentModel` | `PDFResourceSession` | Move to ResourceSession. Single source of truth for file dirty state. |
| `editRevision: Int` | `PDFDocumentModel` | `PDFResourceSession` | Move to ResourceSession. Monotonic edit counter for quit/save guards. |
| `autoSaveStatus: AutoSaveStatus` | `PDFDocumentModel` | `PDFResourceSession` | Move to ResourceSession. Manages debounce task and write state. |
| `markupUndoStack` / `RedoStack` | `PDFDocumentModel` | `PDFResourceSession` | Move to ResourceSession. Document-level edit history. |
| `store: DocumentStore` | `PDFDocumentModel` | `PDFResourceSession` | Move to ResourceSession. Coordinates atomic file I/O. |
| `documentSession: DocumentSession?`| `PDFDocumentModel` | `PDFResourceSession` | Move to ResourceSession. Owns file security lease and versioning. |
| `noteMarkers: [NoteMarker]` | `PDFDocumentModel` | `PDFResourceSession` | Move to ResourceSession. Derived from document annotations. |
| `searchCoordinator` | *New* | `PDFResourceSession` | Coordinates & serializes find operations on `PDFDocument`. |
| `currentPageIndex: Int` | `PDFDocumentModel` | `PDFPaneModel` | Move to PaneModel. Independent viewport position per pane. |
| `pageNavigationRevision: Int` | `PDFDocumentModel` | `PDFPaneModel` | Move to PaneModel. Coordinates viewport navigation commands. |
| `zoomScale: CGFloat` | `PDFDocumentModel` | `PDFPaneModel` | Move to PaneModel. Independent zoom scale per pane. |
| `effectiveScale: CGFloat` | `PDFDocumentModel` | `PDFPaneModel` | Move to PaneModel. Actual scale reported by PDFView. |
| `isAutoScaling: Bool` | `PDFDocumentModel` | `PDFPaneModel` | Move to PaneModel. Auto vs manual zoom mode per pane. |
| `currentSelection: PDFSelection?` | `PDFDocumentModel` | `PDFPaneModel` | Move to PaneModel. Local highlighted text selection. |
| `selectedMarkup: MarkupSelection?` | `PDFDocumentModel` | `PDFPaneModel` | Move to PaneModel. Locally clicked markup annotation. |
| `isSearchPresented: Bool` | `PDFReaderView` | `PDFPaneModel` | Move to PaneModel. In-pane find bar visibility. |
| `searchState` (`inputQuery`, `results`, `currentResultIndex`) | `WorkspaceTabSession` | `PDFPaneModel` | Move to PaneModel. Independent search queries and match index per pane. |
| `navigationState: ReaderNavigationState`| `WorkspaceTabSession` | `PDFPaneModel` | Move to PaneModel. Sidebar visibility and section per pane. |
| `composerStore: NoteComposerStore` | `WorkspaceTabSession` | `PDFPaneModel` | Move to PaneModel. In-flight popover editor anchored to pane view. |
| `activePaneID: UUID?` | `WorkspaceState` | `WorkspaceTab` / `Tree` | Evolve from 1-to-1 tab property to active leaf in tab's layout tree. |

### 2.5 Dual-Pane Shared Document Scenario

Consider a researcher cross-referencing an empirical paper in two split panes:
1. **Pane A** is viewing **Page 3** (Methodology) at 140% zoom with sidebar outline visible.
2. **Pane B** is viewing **Page 22** (Appendix Tables) at 90% zoom with sidebar hidden.
3. Both panes hold a reference to the **same** `PDFResourceSession`.
4. In Pane A, the user searches for "methodology"; in Pane B, the user searches for "appendix".
   - `PDFSearchCoordinator` receives both requests. It executes Pane A's find query first, streaming matches to Pane A's `results` list.
   - It then immediately runs Pane B's query, streaming matches to Pane B's `results` list.
   - Neither pane cancels the other; both viewports display their respective match highlights independently.
5. In Pane A, the user selects a sentence and clicks "Highlight".
   - Pane A dispatches the edit to `PDFResourceSession.addMarkup(.highlight, ...)`.
   - The annotation is added to `PDFDocument.page(at: 2)`.
   - `PDFResourceSession` bumps `annotationRevision`, marks `hasUnsavedChanges = true`, and schedules a debounce autosave task.
   - Pane A redraws its visible page.
   - Pane B is currently rendering Page 22; it is not forced to redraw or jump pages. If the user later scrolls Pane B to Page 3, the newly added highlight is immediately visible because both panes reference the same underlying `PDFDocument`.
6. When autosave fires, `PDFResourceSession` serializes the document once via `DocumentStore`, writing staged bytes atomically to disk.
7. Neither pane experiences UI flicker or navigation resets.

---

## 3. Resource and Session Boundaries: Ownership Hierarchy & Lifecycle

### 3.1 Explicit Ownership Hierarchy

To prevent ambiguity between models and sessions, the architecture establishes this strict hierarchy:

```
WorkspaceTab
├── id: UUID
├── title: String
├── layoutTree: WorkspaceLayoutTree (Geometric binary split tree)
├── activePaneID: PaneID
└── paneSessions: [PaneID: PDFPaneSession] (Local pane registry)
      │
      ├── PDFPaneSession (Pane A)
      │     ├── paneID: PaneID
      │     ├── paneModel: PDFPaneModel (Viewport, page, zoom, search UI, NoteComposer)
      │     └── resourceSession ──┐
      │                           │ (Strong reference to shared resource)
      └── PDFPaneSession (Pane B) │
            ├── paneID: PaneID    │
            ├── paneModel: PDFPaneModel
            └── resourceSession ──┴─► PDFResourceSession
                                        ├── PDFDocument & DocumentVersion
                                        ├── DocumentSession & SecurityScopeLease
                                        ├── Annotation collection & Undo stacks
                                        ├── Dirty tracking & Autosave task
                                        └── PDFSearchCoordinator
```

1. **`WorkspaceTab`**:
   - Owns the `WorkspaceLayoutTree`, the tab title, the `activePaneID`, and the local `paneSessions: [PaneID: PDFPaneSession]` registry.
2. **`PDFPaneSession`**:
   - Owns a stable `PaneID`, its dedicated `PDFPaneModel`, and holds a strong reference to the underlying `PDFResourceSession`.
3. **`PDFPaneModel`**:
   - Owns all viewport and interactive state: current page, zoom scale, auto-scaling flag, local text selection, in-pane search state (`inputQuery`, results, current match index), sidebar navigation state (`ReaderNavigationState`), and active note composer (`NoteComposerStore`).
4. **`PDFResourceSession`**:
   - Owns the canonical `PDFDocument`, `fileURL`, `DocumentSession` (file lease), annotation collection, document-level undo/redo stacks (`markupUndoStack`, `markupRedoStack`), dirty tracking (`hasUnsavedChanges`), autosave debounce task, and `PDFSearchCoordinator`.

### 3.2 Concise Pane & Resource Lifecycle

1. **Creating a Second Pane for an Already-Open PDF**:
   - User triggers "Split Right" or drops a tab into a drop zone.
   - A new `PaneID` is generated.
   - A new `PDFPaneModel` is created (initialized with the source pane's current page and zoom, or default fitted scale).
   - A new `PDFPaneSession` is instantiated, holding the new `PDFPaneModel` and referencing the **existing** `PDFResourceSession`.
   - The new `PaneID` is inserted into `layoutTree` and added to `paneSessions`.
   - No duplicate `PDFDocument`, `DocumentSession`, or security scope is created.
2. **Moving an Existing Pane Between Layout Positions**:
   - User drags a pane title bar to another drop zone or reorders splits.
   - The layout tree is mutated (`WorkspaceLayoutTree.inserting` / `removing`).
   - The `PDFPaneSession`, its `PDFPaneModel`, its uncommitted note drafts, and its `PDFResourceSession` reference remain completely undisturbed.
3. **Closing One of Two Panes Referencing the Same PDF**:
   - User closes Pane A (`⇧⌘W`).
   - Pane A is pruned from `layoutTree` and removed from `paneSessions`.
   - Pane A's `PDFPaneModel` is deallocated.
   - Because Pane B still references `PDFResourceSession`, the shared resource remains fully alive. Document modifications, undo history, and file leases are preserved without interruption.
4. **Closing the Final Pane and Releasing the Resource**:
   - User closes Pane B (the last pane observing `PDFResourceSession`).
   - Pane B is pruned and removed from `paneSessions`.
   - `PDFResourceSession` detects that its active pane lease count is zero.
   - If no asynchronous background tasks (such as an in-flight autosave commit) are running, `DocumentSession.close()` is invoked, safely releasing the security-scoped resource access.
5. **Closing a Tab Containing Multiple Panes**:
   - User closes the tab (`⌘W`).
   - The tab inspects `unsavedWork` across all its `paneSessions` (checking uncommitted note drafts in all `PDFPaneModel`s and dirty document state in all `PDFResourceSession`s).
   - If unsaved changes exist, the user is prompted (`ReaderPromptPolicy`).
   - Upon confirmation, all `PDFPaneSession`s in the tab are dismantled, and any associated `PDFResourceSession` whose active reference count drops to zero is closed cleanly.

### 3.3 Four-Tier Taxonomy Across Content Types

`DocumentStore` and `DocumentSession` are local-file I/O primitives, not universal sessions for all content. The architecture enforces this taxonomy:

```
+-----------------------------------------------------------------------------------+
| PaneKind            | Visual presentation type: .pdf, .markdown, .image,          |
|                     |                          .browser, .agent                   |
+-----------------------------------------------------------------------------------+
| ResourceKind        | Content category: .localPDF, .localMarkdown, .localImage,   |
|                     |                   .webPage, .agentConversation              |
+-----------------------------------------------------------------------------------+
| ResourceDescriptor  | Persistent locator & identity:                              |
|                     |   - Local file: (URL, SecurityBookmark)                     |
|                     |   - Web: URL                                                |
|                     |   - Agent: Conversation UUID                                |
+-----------------------------------------------------------------------------------+
| ResourceSession     | Runtime authority:                                          |
|                     |   - PDFResourceSession (DocumentSession, PDFDocument)       |
|                     |   - MarkdownResourceSession (DocumentSession, TextStorage)  |
|                     |   - ImageResourceSession (DocumentSession, CGImageSource)   |
|                     |   - BrowserSession (WKWebView, WKBackForwardList)           |
|                     |   - AgentConversationSession (MessageLog, ACP stream)       |
+-----------------------------------------------------------------------------------+
```

### 3.4 Evaluation of Resource Types

| Resource Type | Underlying Authority | Persistence Mechanism | Security Scope Required? | Multi-Pane Sharing Rule |
| :--- | :--- | :--- | :--- | :--- |
| **PDF Resource** | `PDFDocument` | `DocumentStore` (atomic staging) | Yes (local file URL) | **Shared**: All panes in window viewing same file share one session. |
| **Markdown Resource** | `NSTextStorage` / AST | `DocumentStore` (atomic staging) | Yes (local file URL) | **Shared**: Panes viewing same `.md` share session and undo stack. |
| **Image Resource** | `CGImageSource` / Image | Read-only (or markup save) | Yes (local file URL) | **Shared**: Panes viewing same image share bitmap cache. |
| **Web Browser** | `WKWebView` / WebKit | Non-persistent or URL cookie | No (Remote network/sandbox) | **Independent**: Each browser pane owns its own back/forward list. |
| **Agent Conversation**| Agent Message Log | SQLite / Local JSON store | No (App container storage) | **Independent or Referenced**: Multiple panes can view different chats. |

### 3.5 Session Scope and Inter-Window Coordination

1. **Window-Scoped Session Pool**:
   - Each `WorkspaceWindowModel` owns a local `ResourceSessionPool` managing active sessions for its tabs and panes.
   - When a pane opens a file, it queries the window's pool. If the file is already open in another pane in that window, the existing `ResourceSession` is reused.
2. **Inter-Window File Coordination**:
   - If two *different* application windows open the same local PDF file, they do **not** share in-memory Swift object pointers.
   - Instead, coordination is handled through Apple's `NSFileCoordinator` and YoPDF's existing `DocumentStore` optimistic locking.
   - If Window A saves changes to disk, Window B's `DocumentSession` detects the change via `checkExternalChange()` on window activation and prompts the user to reload, exactly conforming to standard macOS document architecture (Preview, TextEdit, Xcode).
3. **Session Retention and Safe Lease Release**:
   - Session lifetime is governed by **active leases**, not naive pane reference counting.
   - A `ResourceSession` is retained as long as:
     1. At least one visual Pane references its `ResourceID`.
     2. OR an active asynchronous operation is running (e.g., an in-flight autosave task, a background Markdown export task, or a print task).
   - Only when **all** referencing panes have closed **and** all pending background tasks have finished is `DocumentSession.close()` invoked, safely releasing the security-scoped resource access without risking premature revocation during I/O.

---

## 4. Geometry-Driven Layout Model and Invariants

Rather than relying on arbitrary pane counts or hardcoded display thresholds, YoPDF employs a **Geometry-Driven Layout Engine** operating on logical points.

### 4.1 Recursive Layout Tree

```swift
public enum SplitAxis: String, Codable, Sendable {
    case horizontal // Left & Right children separated by vertical divider
    case vertical   // Top & Bottom children separated by horizontal divider
}

public indirect enum LayoutNode: Equatable, Sendable, Codable {
    case leaf(PaneID)
    case split(
        axis: SplitAxis,
        ratio: Double,
        first: LayoutNode,
        second: LayoutNode
    )
}

public struct WorkspaceLayoutTree: Equatable, Sendable, Codable {
    public private(set) var root: LayoutNode

    public init(leaf: PaneID) {
        self.root = .leaf(leaf)
    }

    public init(root: LayoutNode) {
        self.root = root
    }
}
```

### 4.2 Recursive Dimension Calculation and Configurable Policy

The layout engine enforces minimum visual dimensions recursively through an instance-configurable policy object:

```swift
public struct LayoutPolicy: Equatable, Sendable {
    /// Minimum readable width for any visual leaf pane.
    public var minimumLeafWidth: CGFloat
    /// Minimum readable height for any visual leaf pane.
    public var minimumLeafHeight: CGFloat
    /// Physical divider thickness between split panes.
    public var dividerThickness: CGFloat
    /// Maximum allowable simultaneous panes per tab (configurable policy).
    public var maxPanes: Int

    public init(
        minimumLeafWidth: CGFloat = 320,
        minimumLeafHeight: CGFloat = 240,
        dividerThickness: CGFloat = 1,
        maxPanes: Int = 4
    ) {
        self.minimumLeafWidth = minimumLeafWidth
        self.minimumLeafHeight = minimumLeafHeight
        self.dividerThickness = dividerThickness
        self.maxPanes = maxPanes
    }

    /// Default baseline configuration.
    public static let `default` = LayoutPolicy()
}

extension LayoutNode {
    /// Calculates the minimum required size for this subtree in logical points using the supplied policy.
    public func minimumRequiredSize(policy: LayoutPolicy = .default) -> CGSize {
        switch self {
        case .leaf:
            return CGSize(width: policy.minimumLeafWidth, height: policy.minimumLeafHeight)

        case let .split(axis, _, first, second):
            let firstSize = first.minimumRequiredSize(policy: policy)
            let secondSize = second.minimumRequiredSize(policy: policy)

            switch axis {
            case .horizontal:
                return CGSize(
                    width: firstSize.width + policy.dividerThickness + secondSize.width,
                    height: max(firstSize.height, secondSize.height)
                )
            case .vertical:
                return CGSize(
                    width: max(firstSize.width, secondSize.width),
                    height: firstSize.height + policy.dividerThickness + secondSize.height
                )
            }
        }
    }
}
```

*Note on Initial Values*: The defaults (320pt width, 240pt height, 4 max panes) are documented as initial experimental baselines, not frozen product decisions. The `maxPanes` policy limit is a configurable guardrail, while geometric dimension checks remain the primary architectural protection against unusable viewports.

### 4.3 Dynamic Split Ratio Bounding

For any split node dividing a container of dimension $D$ (width for horizontal, height for vertical) with divider thickness $\delta = \text{policy.dividerThickness}$:
$$\text{availableSpace} = D - \delta$$
$$r_{\min} = \frac{\text{first.minDimension}}{\text{availableSpace}}, \quad r_{\max} = 1 - \frac{\text{second.minDimension}}{\text{availableSpace}}$$

- A split ratio $r$ is valid if and only if $r_{\min} \le r \le r_{\max}$.
- If $r_{\min} > r_{\max}$, the container is physically too small to host the split, and the operation throws `.insufficientSpace`.

### 4.4 Tree Mutation and Error Taxonomy

```swift
public enum LayoutInsertionDirection: Sendable {
    case left, right, top, bottom
}

public enum LayoutMutationError: Error, Equatable, Sendable {
    case targetPaneNotFound(PaneID)
    case duplicatePaneID(PaneID)
    case maximumPaneLimitReached(limit: Int)
    case insufficientSpace(required: CGFloat, available: CGFloat)
    case cannotCloseOnlyPane
}
```

### 4.5 Deserialization Validation and Recovery Strategy

`Codable` synthesizes field deserialization but **cannot** validate structural invariants. A recursive Codable enum may also encounter corrupted JSON that fails decoding before any tree-normalization function can run.

The architecture distinguishes three explicit failure categories and defines recovery for each:

```
+-----------------------------------------------------------------------------------+
| Category A: Successfully Decoded but Semantically Invalid                         |
| - Duplicate PaneIDs, out-of-bounds split ratios, or orphaned split nodes.        |
| - Handled by post-decoding validateAndNormalize(bounds:policy:):                  |
|     1. Prunes duplicate leaves.                                                   |
|     2. Collapses orphaned single-child split nodes into their surviving sibling.  |
|     3. Clamps ratios dynamically to allowable [r_min, r_max] bounds.              |
+-----------------------------------------------------------------------------------+
                                          |
+-----------------------------------------------------------------------------------+
| Category B: Structurally Malformed Serialized Data                                |
| - Missing required enum cases, corrupted JSON syntax, schema version mismatch.    |
| - Handled at the persistence / decoding boundary via do/catch error trapping.     |
| - Fails fast without attempting recursive tree operations on invalid data.        |
+-----------------------------------------------------------------------------------+
                                          |
+-----------------------------------------------------------------------------------+
| Category C: Unrecoverable Layout Fallback                                         |
| - When Category B occurs, or when a decoded tree cannot fit in window bounds.     |
| - Deterministic Fallback: Constructs a clean single-pane layout hosting the       |
|   last known valid resource descriptor (or empty tab), non-destructively          |
|   preserving all user files on disk.                                              |
+-----------------------------------------------------------------------------------+
```

---

## 5. Minimal Viable Migration Strategy for P0-B

### 5.1 P0-B Requirements Baseline

According to [`Docs/P0-B-DRAG-DROP-REQUIREMENTS.md`](file:///Users/lj/Downloads/YoPDF/Docs/P0-B-DRAG-DROP-REQUIREMENTS.md), P0-B is strictly evaluated against:
1. Three entry points: Toolbar (`Split Right` / `Split Down`), Context Menu (`Open in Split Right` / `Open in Split Down`), and Drag & Drop.
2. Four drop zones (`Left`, `Right`, `Top`, `Bottom`) with semi-transparent previews.
3. Preserving existing PDF runtime sessions, zoom, page index, annotations, and uncommitted note drafts during splits.
4. Active Pane command routing for `⌘S`, `⌘Z`, `⌘F`.

### 5.2 Smallest Sound Migration Path

P0-B does **not** require implementing Markdown, Browser, or Agent panes, nor does it require a global multi-type resource bus. The minimal sound migration consists of:

```
+-----------------------------------------------------------------------------------+
| Stage P0-B: Generic Layout Foundation (Hosting PDF Panes Only)                    |
| - Introduce PaneID, LayoutNode, WorkspaceLayoutTree, LayoutPolicy in YoPDFCore     |
| - Update WorkspaceTab: holds layoutTree & paneSessions: [PaneID: PDFPaneSession]  |
| - Update WorkspaceState: tracks activeTabID and activePaneID                      |
| - Implement Drop Zones & Previews on PDFViewerRepresentable                       |
| - Active Pane command routing via activePaneID                                    |
+-----------------------------------------------------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| Stage P0-C: Markdown Note Pane & PDF-Linked Paper Notes (First Heterogeneous Type)|
| - Introduce PaperNoteAssociation & MarkdownResourceSession                        |
| - Native NSTextView / TextKit 2 Markdown Editor                                   |
| - Side-by-side Reading & Citation dropping                                        |
+-----------------------------------------------------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| Stage P0-D: Image & Figure Inspection Pane                                        |
| Stage P1-A: Web Literature Browser Pane (WKWebView)                               |
| Stage P1-B: Agent Pane & Autonomous Research Workflows                            |
+-----------------------------------------------------------------------------------+
```

### 5.3 Staged Abstraction Roadmap

| Abstraction | Phase P0-B (Current Split) | Phase P0-C (Markdown Notes) | Phase P1-A / P1-B (Web & Agent) |
| :--- | :--- | :--- | :--- |
| **`WorkspaceLayoutTree`** | **Required**. Generic binary split engine. | Unchanged. | Unchanged. |
| **`PaneID`** | **Required**. Identifies visual pane. | Unchanged. | Unchanged. |
| **`activePaneID`** | **Required**. Routes keyboard commands. | Unchanged. | Unchanged. |
| **`PDFPaneSession`** | **Required**. Binds PaneModel & Resource. | Unchanged. | Unchanged. |
| **`PDFSearchCoordinator`**| **Required**. Serializes find operations. | Unchanged. | Unchanged. |
| **`PaneKind`** | PDF only (or simple enum). | Add `.markdown`. | Add `.image`, `.browser`, `.agent`. |
| **`ResourceSession`** | PDF session only. | Add `MarkdownResourceSession`. | Add `BrowserSession`, `AgentSession`. |
| **`WorkspaceContext`** | Minimal selection hook. | **ActiveContext** for citations. | Cross-pane agent tool execution. |
| **`PaperNoteAssociation`**| Not in scope. | **Required**. Manages `.notes.md`. | Cross-document knowledge graph. |

---

## 6. Workspace Context Architecture

To support inter-pane collaboration without tight coupling, the architecture clearly distinguishes **ActiveContext** from **WorkspaceAction**:

```
+-----------------------------------------------------------------------------------+
| ActiveContext (Passive, Read-Only Snapshot)                                       |
| - Source Pane ID & Resource ID                                                    |
| - Selected Text snippet                                                           |
| - Spatial SelectionAnchor (Page Index & Normalized Bounding Rect [0..1, 0..1])   |
| - Document Metadata (Title, DOI, Authors, File URL)                               |
+-----------------------------------------------------------------------------------+
                                          |
             Evaluated only upon user interaction; NEVER mutates silently
                                          v
+-----------------------------------------------------------------------------------+
| WorkspaceAction (Explicit User-Initiated Operation)                               |
| - "Cite in Research Note" (Inserts markdown citation)                             |
| - "Search Literature" (Opens browser search with keywords)                         |
| - "Explain Selection with Agent" (Opens prompt in Agent pane)                     |
| - "Navigate to Source" (Jumps companion PDF to page & rect)                       |
+-----------------------------------------------------------------------------------+
```

### 6.1 Rules of Context Collaboration

1. **No Silent Mutations**: Publishing an `ActiveContext` snapshot does **not** automatically mutate other panes. A companion Markdown pane will not insert text, and an Agent pane will not run queries, until the user triggers a deliberate action.
2. **Explicit User Authorization**: Any agent-initiated document modification or file write requires explicit runtime user consent.
3. **No Direct UI Dependencies**: Panes communicate strictly via typed data models passed through the Workspace controller.

---

## 7. Portable Citations and Deep-Link Architecture

### 7.1 Portability Flaw in Absolute Paths

Using absolute local paths (e.g., `yopdf://open?file=/Users/alice/Papers/attention.pdf`) is fundamentally broken:
- It breaks when moving files across devices or collaborating with peers via Git or iCloud.
- It exposes private local username and directory paths.
- External Markdown readers (Obsidian, GitHub, VS Code, Typora) cannot interpret proprietary application schemes.

### 7.2 The CommonMark Portable Standard

YoPDF uses **standard CommonMark relative links** with standard fragment identifiers:

```markdown
According to the multi-head self-attention mechanism proposed in
[Vaswani et al. 2017, p. 5](./attention.pdf#page=5), the attention function is computed...
```

1. **Universal Portability Baseline**:
   - The `#page=5` fragment is the portable standard fallback recognized across external PDF viewers and markdown renderers.
   - The link remains 100% useful without YoPDF installed.
2. **YoPDF Deep-Link Enhancement (Non-Guaranteed External Parameter)**:
   - For precise spatial highlighting inside YoPDF, YoPDF can append a custom fragment parameter:
     `./attention.pdf#page=5&yopdf-rect=0.15,0.22,0.85,0.34`
   - *Compatibility Clarification*: External Markdown readers and third-party PDF viewers are **not guaranteed** to ignore or parse custom query parameters inside URL fragments. Therefore, the architecture treats `yopdf-rect` as a non-essential enhancement; YoPDF's citation generator can generate pure `#page=5` by default or cleanly isolate the parameter.
   - When clicked inside YoPDF, the Workspace parses `yopdf-rect`, focuses or splits the PDF pane, and displays a temporary glowing highlight over the exact passage.
3. **Workspace-Local Resource Resolution**:
   - Links are resolved relative to the Markdown note's directory.
   - If the referenced PDF has been moved, YoPDF's `RecentDocumentsStore` and security-scoped bookmark database attempt resolution by file hash and name before prompting the user to relink.

---

## 8. PDF–Markdown Association Model (`PaperNoteAssociation`)

The primary heterogeneous workflow in YoPDF is reading a PDF while maintaining an associated Markdown research note. This specification prepares for **Stage P0-C** (it is not part of P0-B implementation).

### 8.1 Data Model & Security-Scoped Bookmark Design

```swift
public struct PaperNoteAssociation: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let pdfResourceID: ResourceID
    public let pdfURL: URL
    public let pdfBookmarkData: Data?
    public let pdfContentHash: String

    public var markdownResourceID: ResourceID
    public var markdownURL: URL
    public var markdownBookmarkData: Data?

    public let createdAt: Date
    public var lastModifiedAt: Date

    public init(
        pdfResourceID: ResourceID,
        pdfURL: URL,
        pdfBookmarkData: Data?,
        pdfContentHash: String,
        markdownResourceID: ResourceID,
        markdownURL: URL,
        markdownBookmarkData: Data?
    ) {
        self.id = UUID()
        self.pdfResourceID = pdfResourceID
        self.pdfURL = pdfURL
        self.pdfBookmarkData = pdfBookmarkData
        self.pdfContentHash = pdfContentHash
        self.markdownResourceID = markdownResourceID
        self.markdownURL = markdownURL
        self.markdownBookmarkData = markdownBookmarkData
        self.createdAt = Date()
        self.lastModifiedAt = Date()
    }
}
```

### 8.2 Operational Invariants & Security Lifecycle

1. **The Markdown File is the Sole Source of Truth**:
   - Notes are stored as plain `.md` files on the local filesystem.
   - Notes are **never** embedded inside PDF metadata or proprietary binary annotations.
2. **Security-Scoped Bookmark Persistence & Refresh**:
   - YoPDF creates and stores security-scoped bookmark data for both the PDF and Markdown file (`pdfBookmarkData`, `markdownBookmarkData`).
   - On app restart, bookmarks are resolved via `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)`.
   - If a bookmark is reported as stale, YoPDF immediately re-creates and updates the stored bookmark data.
3. **Role of SHA-256 Content Hash**:
   - A content hash (`pdfContentHash`) is used as a **diagnostic candidate identifier** to locate files if paths change across volumes.
   - It is **not** treated as an unconditional unique identity: two empty files or template files have identical hashes. Resource identity is strictly governed by file URLs and security bookmarks.
4. **Default Naming Convention (Proposed Product Default)**:
   - For a document `attention.pdf`, the default associated note is named `attention.notes.md` in the same directory.
   - *(Note: Designated as a proposed product decision subject to CTO approval; see Section 14).*
5. **External Notebook Vault Support**:
   - Users who manage an existing Obsidian vault, Logseq graph, or research folder can configure a default "Research Notebook Directory".
   - New notes are created inside the vault and linked to the PDF via `PaperNoteAssociation`.
6. **Collision Handling**:
   - If `attention.notes.md` already exists on disk when the user clicks "Create Note", YoPDF **never** overwrites the file silently.
   - Instead, it prompts: *"A note file named 'attention.notes.md' already exists. Would you like to Link Existing Note, Create with New Name, or Choose File?"*
7. **Missing File Recovery**:
   - If a PDF or note is renamed or moved, YoPDF checks its persistent security bookmarks and SHA-256 content hashes to automatically restore the association. If unresolvable, an unobtrusive banner offers a "Relink Note" button.
8. **Association Storage**:
   - Associations are persisted in application support (`~/Library/Application Support/YoPDF/associations.json`), remaining completely transparent and non-destructive to the original PDF.

---

## 9. Refined Quiet.md (`fdl_core`) Evaluation

We inspected `https://github.com/s1dashu/quiet-md` (`crates/core` / `fdl_core` v0.1.10) to evaluate whether its Rust engine should be integrated.

### 9.1 Technical Nuances and Findings

1. **`fdl_core` Independence from GPUI**:
   - Confirmed. `fdl_core` builds independently without GPUI. It depends only on standard Rust crates (`quick-xml`, `serde`, `unicode-segmentation`, `uuid`, `rustc-hash`, `html5ever`).
2. **Document Model: DocxXML vs. Markdown**:
   - `fdl_core`'s native source of truth is **DocxXML** (a proprietary block XML format), *not* Markdown.
   - Markdown is treated as an import/export dialect. Round-tripping standard Markdown through `DocxXML` strips custom spacing, normalizes raw syntax, and can corrupt YAML/TOML frontmatter. For YoPDF, users demand that their Markdown files remain clean, bit-for-bit preserved source text.
3. **Rust FFI and CJK IME Clarification**:
   - Rust FFI itself does *not* break CJK IME. In macOS, IME composition is handled entirely at the window and view layer via `NSTextInputClient`.
   - The true impedance mismatch is architectural: `fdl_core` is designed for a custom GPU text rasterizer (GPUI / `cosmic-text`), whereas native macOS applications achieve superior text editing, dictation, VoiceOver accessibility, and system spellcheck through AppKit's `NSTextView` / TextKit 2.
4. **Parser vs. Editor Distinction**:
   - Parsers like `swift-markdown` (Apple) and `cmark-gfm` are AST parsers, **not** interactive rich-text editing engines.
   - A complete Markdown editor requires an interactive editor engine (`NSTextView` with custom TextKit 2 attributes, or a hybrid WYSIWYG block view).

### 9.2 Recommendation and Future Spike Plan

- **Option A (Rust FFI Binding)**: **REJECTED**. Unnecessary foreign dependency, DocxXML model round-trip lossiness, and complex cross-language maintenance.
- **Option B & C (Adopt Block Concepts; Implement Native Swift Engine)**: **RECOMMENDED**.
  - Adopt `fdl_core`'s clean block taxonomy as conceptual design references.
  - Implement the Markdown editor in native Swift using AppKit `NSTextView` and TextKit 2.
- **Markdown Editor Proof-of-Concept (PoC) Spike Scope (Deferred to P0-C)**:
  Before implementing the full editor in P0-C, a focused spike will validate:
  1. `NSTextView` / TextKit 2 live syntax styling performance on large notes (> 10,000 words).
  2. Exact source round-tripping preserving raw whitespace and custom formatting.
  3. CJK IME composition with active syntax highlight attributes.
  4. Non-destructive YAML frontmatter parsing and preservation.
  5. Rendering of embedded tables, code blocks, images, and LaTeX equations.
  6. Atomic persistence and external file change detection via `DocumentStore`.

---

## 10. Layout Rendering Engine Evaluation & Spike Plan

The choice between a **Pure SwiftUI Recursive Layout** and an **AppKit `NSSplitViewController`** wrapper must be decided empirically, rather than by dismissing either framework prematurely.

### 10.1 Structured Trade-Off Comparison

| Evaluation Factor | Pure SwiftUI Recursive Tree | AppKit `NSSplitViewController` Representable |
| :--- | :--- | :--- |
| **State Synchronization** | Declarative 1:1 binding with `WorkspaceLayoutTree`. Zero sync lag. | Requires bridging declarative state into AppKit delegate callbacks. |
| **Divider Resizing** | Custom divider drag gesture; direct ratio calculation. | Native macOS system divider behavior and cursor management out-of-the-box. |
| **Nested Split Stability** | High predictability; purely functional geometry calculation. | Hypothesis to evaluate: Auto Layout constraint recursion in deeply nested splits. |
| **Drop Zone Overlays** | Native SwiftUI `.overlay` with seamless translucency and animations. | Requires injecting custom AppKit overlay views over split items. |
| **Accessibility (VoiceOver)**| Native SwiftUI accessibility element tree. | Mature native AppKit accessibility hierarchy. |
| **Implementation Complexity** | Low-to-medium; straightforward recursion in SwiftUI. | Medium-to-high; complex `NSViewControllerRepresentable` coordinator. |

### 10.2 Decision Status: Kept Open for Spike

This architectural decision remains **open** until a focused P0-B layout spike tests both implementations against:
1. Smooth 120Hz trackpad divider dragging without layout stutter.
2. Stability of 3-level nested splits during rapid window resizing.
3. Clean drag-and-drop hit-testing over the four drop zones.
4. VoiceOver navigation across split panes.

---

## 11. Command Routing and First-Responder Lifecycle

In a multi-panel workspace, menu commands must deterministically target the **Active Pane**.

### 11.1 Active Pane Focus

1. **Selection Invariant**: Clicking anywhere inside a pane sets it as the Workspace's `activePaneID`.
2. **Visual Focus Indicator**: The active pane displays a subtle native 1.5pt accent border or titlebar highlight.
3. **Responder Protocol**:

```swift
@MainActor
public protocol PaneCommandResponder: AnyObject {
    var paneID: PaneID { get }
    var paneKind: PaneKind { get }

    // File operations
    var canSave: Bool { get }
    func save()
    var canSaveAs: Bool { get }
    func saveAs()

    // Edit operations
    var canUndo: Bool { get }
    func undo()
    var canRedo: Bool { get }
    func redo()

    // Search operations
    var canFind: Bool { get }
    func find()

    // Navigation / Viewport
    var canZoom: Bool { get }
    func zoomIn()
    func zoomOut()
    func resetZoom()
}
```

### 11.2 Command Routing Table

| Command | Shortcut | Routing Target | Behavior & Fallback |
| :--- | :--- | :--- | :--- |
| **Save** | `⌘S` | Active Pane's `ResourceSession` | Saves active document. Disabled if active pane has no unsaved changes or is read-only. |
| **Save As…** | `⇧⌘S` | Active Pane's `ResourceSession` | Presents `NSSavePanel` for active document. |
| **Undo / Redo**| `⌘Z` / `⇧⌘Z` | Active Pane's Undo Stack | Dispatched to active pane's undo coordinator. |
| **Find in Document**| `⌘F` | Active Pane | Activates in-pane find bar. |
| **Zoom In / Out**| `⌘+` / `⌘-` | Active Pane | Adjusts active pane's `zoomScale`. |
| **Close Pane** | `⇧⌘W` | Active Pane | Closes active pane; prunes layout tree. Prompts if unsaved edits exist. |
| **Close Tab** | `⌘W` | Active Tab | Closes active tab. Prompts for unsaved edits across all panes in tab. |

---

## 12. Testing and Conformance Strategy

To guarantee that existing PDF functionality never regresses while multi-panel features are introduced, the test suite must cover:

### 12.1 Layout Tree Geometry Tests (`WorkspaceLayoutTreeTests.swift`)
1. `testRecursiveMinimumSizeCalculation()`: Verifies that nested horizontal/vertical splits correctly sum child minimum dimensions and divider widths using the supplied `LayoutPolicy`.
2. `testSplitRatioBoundingPreventsZeroPixelPanes()`: Ensures ratios are clamped dynamically to prevent violating minimum dimensions.
3. `testInsufficientSpaceErrorThrownWhenWindowTooNarrow()`: Validates that attempting to split a window below minimum dimensions returns `.insufficientSpace`.
4. `testPruningLeafCollapsesParentSplitNode()`: Ensures removing a leaf collapses the split node directly into the surviving sibling.
5. `testDeserializationNormalizationRepairsCorruptedTree()`: Verifies that trees with duplicate or orphaned IDs are sanitized without crashing.

### 12.2 Multi-Pane Resource Sharing & Search Tests (`ResourceSessionTests.swift`)
1. `testDualPanesShareSinglePDFDocumentInstance()`: Opening the same URL in two panes shares the same in-memory `PDFDocument`.
2. `testIndependentNavigationInSharedPanes()`: Navigating Page in Pane A does not alter `currentPageIndex` in Pane B.
3. `testAnnotationAddedInPaneAVisibleInPaneB()`: Adding a highlight in Pane A updates the shared model and appears when Pane B views that page.
4. `testSingleAutosaveDebounceAcrossSharedPanes()`: Multiple rapid edits across shared panes collapse into a single atomic write.
5. `testSessionLeaseReleasedOnlyWhenAllPanesClose()`: Closing Pane 1 keeps the security lease alive for Pane 2; closing Pane 2 releases the lease.
6. `testSearchCoordinatorSerializesQueriesAcrossPanes()`: Verifies that Pane A searching "methodology" and Pane B searching "appendix" execute sequentially without cancelling or intercepting each other's results.

### 12.3 Note Draft and Association Tests (`NoteAssociationTests.swift`)
1. `testUncommittedNoteDraftBlocksTabCloseWithoutPrompt()`: Ensures in-flight drafts in any split pane trigger the "Save note first?" prompt.
2. `testNoteAnchorPreservedAcrossPaneResizingAndReparenting()`: Ensures that resizing or moving a pane preserves the logical anchor (`pageIndex`, `bounds`) and recomputes `anchorRect` via `PageAnchorResolver`.
3. `testAssociatedNoteDoesNotOverwriteExistingFile()`: Verifies collision handling prompts the user rather than overwriting existing `.notes.md`.
4. `testRelativeCommonMarkCitationResolution()`: Verifies that clicking `./paper.pdf#page=5` accurately opens and navigates the companion PDF pane.

---

## 13. Risks and Trade-offs

| Decision / Area | Trade-off & Risk | Mitigation Strategy |
| :--- | :--- | :--- |
| **Shared Resource Session Concurrency** | Two panes modifying the same document simultaneously could cause race conditions. | All document mutations, annotation updates, and UI events are strictly pinned to `@MainActor`. `DocumentSession` protects disk I/O via serial operation locks. |
| **Memory Footprint of Multi-Panes** | Hosting multiple high-DPI PDF views or WebViews simultaneously can elevate RAM usage. | Limit maximum panes per tab (configurable `maxPanes`); release off-screen render caches; suspend background WebViews. |
| **TextKit 2 Custom Attributes** | Modern TextKit 2 has occasional edge cases with complex custom paragraph spacing attributes. | Encapsulate Markdown text storage behind an abstract interface, allowing fallback to TextKit 1 if complex block decorations require it. |

---

## 14. Decision Status Table

To ensure architectural clarity, all technical decisions are categorized into explicit statuses:

| Decision ID | Topic | Proposed Choice | Status | Authority / Requirement |
| :--- | :--- | :--- | :--- | :--- |
| **DEC-01** | **Three-Tier Decoupling** | Workspace $\rightarrow$ Pane $\rightarrow$ Resource/Session separation. | **FROZEN** | Core Architectural Invariant. |
| **DEC-02** | **Single File Leasing** | Panes viewing the same file share one `ResourceSession`; zero duplicate uncoordinated editable instances. | **FROZEN** | Core Data Safety Invariant. |
| **DEC-03** | **Offline & Local-First** | Reading, notes, and persistence must work 100% offline without remote server dependencies. | **FROZEN** | AGENTS.md / Core Principle. |
| **DEC-04** | **Note Storage Format** | Standalone portable `.md` files; no proprietary PDF metadata embedding. | **FROZEN** | Core Interoperability Rule. |
| **DEC-05** | **User Action Boundary** | No silent background mutations from companion panes or agents; explicit user authorization required. | **FROZEN** | Core Security Rule. |
| **DEC-06** | **Search Serialization** | `PDFSearchCoordinator` serializes find operations on `PDFDocument`. | **FROZEN** | PDFKit Technical Constraint. |
| **DEC-07** | **Logical Note Anchor** | Persistent page-space anchor (`pageIndex`, `bounds`) with derived presentation `anchorRect`. | **FROZEN** | Core Reliability Invariant. |
| **DEC-08** | **Layout Engine Technology** | Pure SwiftUI recursive layout vs. AppKit `NSSplitViewController`. | **RECOMMENDED (UNVERIFIED)** | Requires focused spike in P0-B. |
| **DEC-09** | **Markdown Engine** | Native AppKit `NSTextView` / TextKit 2 (rejecting Rust FFI). | **RECOMMENDED (UNVERIFIED)** | Requires focused PoC in P0-C. |
| **DEC-10** | **Citation Link Format** | Relative CommonMark links (`./paper.pdf#page=N`) with optional non-destructive query params. | **RECOMMENDED (UNVERIFIED)** | Verification in P0-C. |
| **DEC-11** | **Layout Policy Configuration** | Configurable `LayoutPolicy` instance (defaulting to 320x240pt, 1pt divider, 4 max panes). | **RECOMMENDED (CONFIGURABLE)** | Configurable Defaults. |
| **DEC-12** | **Default Note Naming** | `<paper-name>.notes.md` sidecar convention. | **PROPOSED PRODUCT DECISION** | Requires CTO / Product Approval. |
| **DEC-13** | **Notebook Directory Setting**| Configurable external research notebook / Obsidian vault directory. | **PROPOSED PRODUCT DECISION** | Requires CTO / Product Approval. |
| **DEC-14** | **Browser Session Pooling** | Process pooling and cookie persistence policies for Web Browser pane. | **DEFERRED** | Deferred to Phase P1-A. |
| **DEC-15** | **Agent Protocol Transport** | AgentChat / ACP integration adapter and tool schema. | **DEFERRED** | Deferred to Phase P1-B. |

---

## 15. Conclusion and Next Steps

This final revised contract establishes a rigorous, concrete foundation for YoPDF. By decoupling the shared PDF Resource state from individual visual Pane view states, introducing `PDFSearchCoordinator` to serialize search operations, stabilizing note composer anchors across pane movement, and parameterizing layout constraints, YoPDF ensures:
- Existing PDFKit reading, annotation, and safe atomic persistence remain 100% stable and intact.
- A second Coding Agent can implement P0-B's generic layout foundation immediately without inventing ownership boundaries or concurrency rules.
- Future heterogeneous panes (Markdown, Image, Browser, Agent) can be introduced incrementally without modifying the core layout engine.

**Immediate Next Action**:
Begin **Stage P0-B Layout Spike**:
1. Implement `PaneID`, `LayoutNode`, `WorkspaceLayoutTree`, and `LayoutPolicy` in `YoPDFCore`.
2. Implement unit tests in `YoPDFTests/WorkspaceLayoutTreeTests.swift` validating dimension calculations, dynamic ratio bounding, and split collapse.
3. Wire `WorkspaceLayoutTree` into `WorkspaceState` to support multi-pane PDF viewing.
