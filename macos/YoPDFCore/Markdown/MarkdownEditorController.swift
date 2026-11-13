//
//  MarkdownEditorController.swift
//  YoPDFCore
//
//  Created for Task P0-C-A: Native Markdown Editor.
//  Apache-2.0 Open Source License.
//

import Combine
import Foundation

/// Host seam implemented by the underlying AppKit text view coordinator/view.
@MainActor
public protocol MarkdownEditorHost: AnyObject {
    var currentText: String { get }
    var selectedRange: NSRange { get set }
    var activeEngine: MarkdownTextEngine { get }
    var isFirstResponder: Bool { get }
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    var lastHighlightStats: MarkdownHighlightStats? { get }

    @discardableResult
    func focus(restoringSelection selection: NSRange?) -> Bool
    func setSelection(_ range: NSRange, scrollToVisible: Bool)
    func scrollToRange(_ range: NSRange)

    @discardableResult
    func insertText(_ text: String, replacing range: NSRange?) -> Bool

    @discardableResult
    func performUndo() -> Bool

    @discardableResult
    func performRedo() -> Bool
}

/// Imperative control & state-restoration handle for `MarkdownEditorView`.
///
/// A parent pane model can retain a `MarkdownEditorController` across SwiftUI
/// view reconstructions (such as tab switches or split-pane reparenting) to
/// restore focus, cursor/selection range, and scroll visibility cleanly.
@MainActor
public final class MarkdownEditorController: ObservableObject {

    @Published public private(set) var isFirstResponder: Bool = false
    @Published public private(set) var selectedRange: NSRange = NSRange(location: 0, length: 0)
    @Published public private(set) var canUndo: Bool = false
    @Published public private(set) var canRedo: Bool = false
    @Published public private(set) var activeEngine: MarkdownTextEngine = .textKit2
    public private(set) var lastHighlightStats: MarkdownHighlightStats?

    /// Selection queued to be restored when the editor next mounts or enters a window.
    public var pendingSelection: NSRange?
    /// Scroll target queued for the next mount/layout pass.
    public var pendingScrollRange: NSRange?
    /// Focus request queued until the editor attaches to an `NSWindow`.
    public var pendingFocusRequest: Bool = false

    private weak var host: (any MarkdownEditorHost)?

    public init() {}

    public func attach(host: any MarkdownEditorHost) {
        self.host = host
        lastHighlightStats = host.lastHighlightStats

        if let pendingSelection {
            host.setSelection(pendingSelection, scrollToVisible: pendingScrollRange == nil)
            self.pendingSelection = nil
        }
        if let pendingScrollRange {
            host.scrollToRange(pendingScrollRange)
            self.pendingScrollRange = nil
        }
        if pendingFocusRequest {
            if host.focus(restoringSelection: nil) {
                pendingFocusRequest = false
            }
        }
        // Defer @Published updates out of SwiftUI's makeNSView/updateNSView pass.
        DispatchQueue.main.async { [weak self] in
            self?.syncStateFromHost()
        }
    }

    public func detach(host: any MarkdownEditorHost, notifyObservers: Bool = true) {
        guard self.host === host else { return }
        self.host = nil
        if notifyObservers && isFirstResponder {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.host == nil else { return }
                self.isFirstResponder = false
            }
        }
    }

    public func syncStateFromHost() {
        guard let host else { return }
        let observedSelection = host.selectedRange
        if selectedRange != observedSelection {
            selectedRange = observedSelection
        }
        let observedFirstResponder = host.isFirstResponder
        if isFirstResponder != observedFirstResponder {
            isFirstResponder = observedFirstResponder
        }
        let observedCanUndo = host.canUndo
        if canUndo != observedCanUndo {
            canUndo = observedCanUndo
        }
        let observedCanRedo = host.canRedo
        if canRedo != observedCanRedo {
            canRedo = observedCanRedo
        }
        if activeEngine != host.activeEngine {
            activeEngine = host.activeEngine
        }
        if lastHighlightStats != host.lastHighlightStats {
            lastHighlightStats = host.lastHighlightStats
        }
    }

    /// Requests first-responder focus, optionally restoring a selection range.
    ///
    /// If the editor is not currently attached to a window, the request is queued
    /// and applied automatically once `viewDidMoveToWindow()` fires.
    @discardableResult
    public func focus(restoringSelection selection: NSRange? = nil) -> Bool {
        if let selection {
            pendingSelection = selection
        }
        guard let host else {
            pendingFocusRequest = true
            return false
        }
        let focused = host.focus(restoringSelection: selection)
        if focused {
            pendingFocusRequest = false
            pendingSelection = nil
        } else {
            pendingFocusRequest = true
        }
        syncStateFromHost()
        return focused
    }

    /// Sets the selection range (clamped safely to document bounds).
    public func setSelection(_ range: NSRange, scrollToVisible: Bool = true) {
        guard let host else {
            pendingSelection = range
            if scrollToVisible {
                pendingScrollRange = range
            }
            return
        }
        pendingSelection = nil
        host.setSelection(range, scrollToVisible: scrollToVisible)
        syncStateFromHost()
    }

    /// Scrolls the viewport so `range` is visible without changing selection.
    public func scrollToRange(_ range: NSRange) {
        guard let host else {
            pendingScrollRange = range
            return
        }
        pendingScrollRange = nil
        host.scrollToRange(range)
    }

    /// Inserts `text` using `NSTextView`'s undoable editing pipeline.
    @discardableResult
    public func insertText(_ text: String, replacing range: NSRange? = nil) -> Bool {
        guard let host else { return false }
        let inserted = host.insertText(text, replacing: range)
        syncStateFromHost()
        return inserted
    }

    @discardableResult
    public func undo() -> Bool {
        guard let host else { return false }
        let undone = host.performUndo()
        syncStateFromHost()
        return undone
    }

    @discardableResult
    public func redo() -> Bool {
        guard let host else { return false }
        let redone = host.performRedo()
        syncStateFromHost()
        return redone
    }
}
