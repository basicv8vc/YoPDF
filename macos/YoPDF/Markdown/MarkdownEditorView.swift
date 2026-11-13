//
//  MarkdownEditorView.swift
//  YoPDF
//
//  Created for Task P0-C-A: Native Markdown Editor.
//  Apache-2.0 Open Source License.
//

import AppKit
import SwiftUI
import YoPDFCore

/// Production-usable native macOS Markdown source editor backed by AppKit `NSTextView`.
///
/// Design invariants:
/// - **Authoritative source text**: Raw Markdown is never rewritten or round-tripped through an AST.
/// - **Presentation-only highlighting**: Syntax styling never alters `textStorage.string` characters.
/// - **IME-safe**: Skips syntax re-highlighting while `hasMarkedText()` is true so Chinese/Japanese
///   input methods retain native marked text underlines and candidate positioning.
/// - **Pane-isolated Undo/Redo**: Uses a per-editor `UndoManager` so edits never collide with PDF
///   annotations or sibling split panes.
public struct MarkdownEditorView: View {
    @Binding private var text: String
    private let selection: Binding<NSRange>?
    private let configuration: MarkdownEditorConfiguration
    private let controller: MarkdownEditorController?
    private let onTextChange: ((String) -> Void)?
    private let onSelectionChange: ((NSRange) -> Void)?
    private let onFocusChange: ((Bool) -> Void)?

    public init(
        text: Binding<String>,
        selection: Binding<NSRange>? = nil,
        configuration: MarkdownEditorConfiguration = .default,
        controller: MarkdownEditorController? = nil,
        onTextChange: ((String) -> Void)? = nil,
        onSelectionChange: ((NSRange) -> Void)? = nil,
        onFocusChange: ((Bool) -> Void)? = nil
    ) {
        self._text = text
        self.selection = selection
        self.configuration = configuration
        self.controller = controller
        self.onTextChange = onTextChange
        self.onSelectionChange = onSelectionChange
        self.onFocusChange = onFocusChange
    }

    public var body: some View {
        MarkdownEditorRepresentable(
            text: $text,
            selection: selection,
            configuration: configuration,
            controller: controller,
            onTextChange: onTextChange,
            onSelectionChange: onSelectionChange,
            onFocusChange: onFocusChange
        )
        .accessibilityElement(children: .contain)
    }
}

// MARK: - NSViewRepresentable Bridge

private struct MarkdownEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    let selection: Binding<NSRange>?
    let configuration: MarkdownEditorConfiguration
    let controller: MarkdownEditorController?
    let onTextChange: ((String) -> Void)?
    let onSelectionChange: ((NSRange) -> Void)?
    let onFocusChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !configuration.wrapsLines
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        let textView = MarkdownNSTextView(engine: configuration.preferredEngine)
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.onEffectiveAppearanceChange = { [weak coordinator = context.coordinator] in
            coordinator?.handleAppearanceChanged()
        }
        textView.onFirstResponderChange = { [weak coordinator = context.coordinator] isFocused in
            coordinator?.handleFirstResponderChanged(isFocused)
        }
        textView.onWindowAttachment = { [weak coordinator = context.coordinator] in
            coordinator?.handleWindowAttachment()
        }
        textView.onMarkedTextEnded = { [weak coordinator = context.coordinator] priorMarkedRange in
            coordinator?.handleMarkedTextEnded(priorMarkedRange)
        }

        scrollView.documentView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView

        context.coordinator.applyConfiguration(configuration, colorScheme: context.environment.colorScheme, forceHighlight: true)
        context.coordinator.syncInitialText(text, selection: selection?.wrappedValue)
        controller?.attach(host: context.coordinator)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard let textView = context.coordinator.textView else { return }

        if context.coordinator.attachedController !== controller {
            context.coordinator.attachedController?.detach(host: context.coordinator)
            context.coordinator.attachedController = controller
            controller?.attach(host: context.coordinator)
        }

        context.coordinator.applyConfiguration(
            configuration,
            colorScheme: context.environment.colorScheme,
            forceHighlight: false
        )
        context.coordinator.syncExternalTextIfNeeded(text)
        context.coordinator.syncExternalSelectionIfNeeded(selection?.wrappedValue)

        // Ensure horizontal scroller tracks line-wrap changes cleanly.
        if scrollView.hasHorizontalScroller != !configuration.wrapsLines {
            scrollView.hasHorizontalScroller = !configuration.wrapsLines
        }
        _ = textView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.attachedController?.detach(host: coordinator, notifyObservers: false)
        coordinator.attachedController = nil
        scrollView.documentView = nil
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, MarkdownEditorHost {
        var parent: MarkdownEditorRepresentable
        weak var scrollView: NSScrollView?
        var textView: MarkdownNSTextView?
        weak var attachedController: MarkdownEditorController?

        private let highlighter = MarkdownSyntaxHighlighter()
        private let isolatedUndoManager = UndoManager()
        private var currentConfiguration: MarkdownEditorConfiguration
        private var currentPalette: MarkdownEditorPalette
        private var isSyncingFromModel = false
        private var isApplyingHighlighting = false
        private var pendingEditedRange: NSRange?
        private var activeMarkedRange: NSRange?
        private var pendingPaletteRehighlight = false
        private var lastSyncedText: String = ""
        private(set) var lastHighlightStats: MarkdownHighlightStats?

        init(parent: MarkdownEditorRepresentable) {
            self.parent = parent
            self.currentConfiguration = parent.configuration
            self.attachedController = parent.controller
            self.currentPalette = MarkdownEditorPalette.resolved(
                theme: parent.configuration.theme,
                appearance: nil,
                fontSize: parent.configuration.fontSize,
                lineHeightMultiple: parent.configuration.lineHeightMultiple
            )
            super.init()
        }

        // MARK: - MarkdownEditorHost

        var currentText: String {
            textView?.string ?? ""
        }

        var selectedRange: NSRange {
            get { textView?.selectedRange() ?? NSRange(location: 0, length: 0) }
            set { setSelection(newValue, scrollToVisible: false) }
        }

        var activeEngine: MarkdownTextEngine {
            textView?.activeEngine ?? .textKit2
        }

        var isFirstResponder: Bool {
            guard let textView, let window = textView.window else { return false }
            return window.firstResponder === textView
        }

        var canUndo: Bool {
            isolatedUndoManager.canUndo
        }

        var canRedo: Bool {
            isolatedUndoManager.canRedo
        }

        @discardableResult
        func focus(restoringSelection selection: NSRange?) -> Bool {
            guard let textView else { return false }
            if let selection {
                setSelection(selection, scrollToVisible: true)
            }
            guard let window = textView.window else { return false }
            return window.makeFirstResponder(textView)
        }

        func setSelection(_ range: NSRange, scrollToVisible: Bool) {
            guard let textView else { return }
            guard !textView.hasMarkedText() else { return }
            let clamped = Self.clampedSelection(range, utf16Length: (textView.string as NSString).length)
            if textView.selectedRange() != clamped {
                isSyncingFromModel = true
                textView.setSelectedRange(clamped)
                isSyncingFromModel = false
            }
            if scrollToVisible {
                textView.scrollRangeToVisible(clamped)
            }
            if let selectionBinding = parent.selection, selectionBinding.wrappedValue != clamped {
                selectionBinding.wrappedValue = clamped
            }
            updateTypingAttributes()
        }

        func scrollToRange(_ range: NSRange) {
            guard let textView else { return }
            let clamped = Self.clampedSelection(range, utf16Length: (textView.string as NSString).length)
            textView.scrollRangeToVisible(clamped)
        }

        @discardableResult
        func insertText(_ text: String, replacing range: NSRange?) -> Bool {
            guard let textView, textView.isEditable else { return false }
            let currentLength = (textView.string as NSString).length
            let targetRange = Self.clampedSelection(range ?? textView.selectedRange(), utf16Length: currentLength)

            guard textView.shouldChangeText(in: targetRange, replacementString: text) else {
                return false
            }
            pendingEditedRange = targetRange
            textView.replaceCharacters(in: targetRange, with: text)
            textView.didChangeText()

            let insertedLength = (text as NSString).length
            let caret = NSRange(location: targetRange.location + insertedLength, length: 0)
            textView.setSelectedRange(caret)
            textView.scrollRangeToVisible(caret)
            return true
        }

        @discardableResult
        func performUndo() -> Bool {
            guard isolatedUndoManager.canUndo else { return false }
            textView?.breakUndoCoalescing()
            isolatedUndoManager.undo()
            syncAfterUndoOrRedoIfNeeded()
            return true
        }

        @discardableResult
        func performRedo() -> Bool {
            guard isolatedUndoManager.canRedo else { return false }
            textView?.breakUndoCoalescing()
            isolatedUndoManager.redo()
            syncAfterUndoOrRedoIfNeeded()
            return true
        }

        private func syncAfterUndoOrRedoIfNeeded() {
            guard let textView else { return }
            guard !textView.hasMarkedText() else { return }
            let updatedText = textView.string
            guard !Self.utf8Equal(updatedText, lastSyncedText) else { return }
            lastSyncedText = updatedText
            applyHighlighting(editedRange: nil)
            updateTypingAttributes()
            if !Self.utf8Equal(parent.text, updatedText) {
                parent.text = updatedText
            }
            parent.onTextChange?(updatedText)
            let currentRange = textView.selectedRange()
            if let selectionBinding = parent.selection, selectionBinding.wrappedValue != currentRange {
                selectionBinding.wrappedValue = currentRange
            }
            attachedController?.syncStateFromHost()
        }

        // MARK: - Configuration & Theme

        func applyConfiguration(
            _ configuration: MarkdownEditorConfiguration,
            colorScheme: ColorScheme,
            forceHighlight: Bool
        ) {
            guard let textView, let scrollView else { return }
            let previousConfig = currentConfiguration
            currentConfiguration = configuration

            // Apply explicit NSAppearance override or inherit SwiftUI/system appearance.
            let targetAppearance: NSAppearance?
            switch configuration.theme {
            case .light:
                targetAppearance = NSAppearance(named: .aqua)
            case .dark:
                targetAppearance = NSAppearance(named: .darkAqua)
            case .system:
                targetAppearance = nil
            }

            if scrollView.appearance !== targetAppearance {
                scrollView.appearance = targetAppearance
            }
            if textView.appearance !== targetAppearance {
                textView.appearance = targetAppearance
            }

            let resolvedAppearance: NSAppearance? = {
                if let targetAppearance { return targetAppearance }
                switch colorScheme {
                case .dark: return NSAppearance(named: .darkAqua)
                case .light: return NSAppearance(named: .aqua)
                @unknown default: return textView.effectiveAppearance
                }
            }()

            let nextPalette = MarkdownEditorPalette.resolved(
                theme: configuration.theme,
                appearance: resolvedAppearance,
                fontSize: configuration.fontSize,
                lineHeightMultiple: configuration.lineHeightMultiple
            )
            let paletteChanged = nextPalette != currentPalette
            currentPalette = nextPalette

            textView.isEditable = configuration.isEditable
            textView.isSelectable = configuration.isSelectable
            textView.isContinuousSpellCheckingEnabled = configuration.continuousSpellCheckingEnabled
            textView.textContainerInset = NSSize(
                width: configuration.contentInsets.horizontal,
                height: configuration.contentInsets.vertical
            )

            if previousConfig.wrapsLines != configuration.wrapsLines || forceHighlight {
                textView.configureLineWrapping(configuration.wrapsLines, containerWidth: scrollView.contentSize.width)
            }

            scrollView.backgroundColor = nextPalette.editorBackground
            textView.backgroundColor = nextPalette.editorBackground
            textView.insertionPointColor = nextPalette.insertionPoint

            if paletteChanged || forceHighlight {
                if textView.hasMarkedText() {
                    pendingPaletteRehighlight = true
                } else {
                    // Only update plain-text base properties when the palette actually changed,
                    // because assigning `NSTextView.font`/`textColor` resets attributes on the whole textStorage.
                    textView.font = nextPalette.bodyFont
                    textView.textColor = nextPalette.bodyText
                    textView.defaultParagraphStyle = nextPalette.defaultParagraphStyle
                    highlighter.invalidateCache()
                    applyHighlighting(editedRange: nil)
                    pendingPaletteRehighlight = false
                }
            }
            updateTypingAttributes()
        }

        func handleAppearanceChanged() {
            guard currentConfiguration.theme == .system, let textView else { return }
            let nextPalette = MarkdownEditorPalette.resolved(
                theme: .system,
                appearance: textView.effectiveAppearance,
                fontSize: currentConfiguration.fontSize,
                lineHeightMultiple: currentConfiguration.lineHeightMultiple
            )
            guard nextPalette != currentPalette else { return }
            currentPalette = nextPalette
            scrollView?.backgroundColor = nextPalette.editorBackground
            textView.backgroundColor = nextPalette.editorBackground
            textView.insertionPointColor = nextPalette.insertionPoint
            if textView.hasMarkedText() {
                pendingPaletteRehighlight = true
            } else {
                textView.font = nextPalette.bodyFont
                textView.textColor = nextPalette.bodyText
                textView.defaultParagraphStyle = nextPalette.defaultParagraphStyle
                highlighter.invalidateCache()
                applyHighlighting(editedRange: nil)
                pendingPaletteRehighlight = false
                updateTypingAttributes()
            }
        }

        func handleFirstResponderChanged(_ isFocused: Bool) {
            attachedController?.syncStateFromHost()
            parent.onFocusChange?(isFocused)
        }

        func handleWindowAttachment() {
            guard let controller = attachedController else { return }
            if let pendingSelection = controller.pendingSelection {
                setSelection(pendingSelection, scrollToVisible: controller.pendingScrollRange == nil)
                controller.pendingSelection = nil
            }
            if let pendingScroll = controller.pendingScrollRange {
                scrollToRange(pendingScroll)
                controller.pendingScrollRange = nil
            }
            if controller.pendingFocusRequest {
                if focus(restoringSelection: nil) {
                    controller.pendingFocusRequest = false
                }
            }
            DispatchQueue.main.async { [weak controller] in
                controller?.syncStateFromHost()
            }
        }

        func handleMarkedTextEnded(_ priorMarkedRange: NSRange) {
            guard let textView, !textView.hasMarkedText() else { return }
            let updatedText = textView.string
            let maxLen = (updatedText as NSString).length
            let edited = Self.mergedEditedRange(
                pending: pendingEditedRange,
                marked: priorMarkedRange.location == NSNotFound ? activeMarkedRange : priorMarkedRange,
                fallback: textView.selectedRange(),
                maxLength: maxLen
            )
            pendingEditedRange = nil
            activeMarkedRange = nil

            if pendingPaletteRehighlight {
                applyPaletteBaseAttributes(to: textView, palette: currentPalette)
                highlighter.invalidateCache()
                applyHighlighting(editedRange: nil)
                pendingPaletteRehighlight = false
            } else {
                applyHighlighting(editedRange: edited)
            }
            updateTypingAttributes()

            let changed = !Self.utf8Equal(updatedText, lastSyncedText)
            lastSyncedText = updatedText
            if !Self.utf8Equal(parent.text, updatedText) {
                parent.text = updatedText
            }
            if changed {
                parent.onTextChange?(updatedText)
            }
            let currentRange = textView.selectedRange()
            if let selectionBinding = parent.selection, selectionBinding.wrappedValue != currentRange {
                selectionBinding.wrappedValue = currentRange
            }
            attachedController?.syncStateFromHost()
        }

        // MARK: - Initial & External Text/Selection Sync

        func syncInitialText(_ text: String, selection: NSRange?) {
            guard let textView else { return }
            isSyncingFromModel = true
            pendingEditedRange = nil
            activeMarkedRange = nil
            pendingPaletteRehighlight = false
            lastSyncedText = text
            if let textStorage = textView.textStorage {
                isApplyingHighlighting = true
                lastHighlightStats = highlighter.replaceText(in: textStorage, with: text, palette: currentPalette)
                isApplyingHighlighting = false
            } else {
                textView.string = text
            }

            if let selection {
                let clamped = Self.clampedSelection(selection, utf16Length: (text as NSString).length)
                textView.setSelectedRange(clamped)
            }
            isSyncingFromModel = false
            updateTypingAttributes()
        }

        func syncExternalTextIfNeeded(_ text: String) {
            guard let textView else { return }
            guard !textView.hasMarkedText() else { return }
            // Never overwrite textView.string when exact UTF-8 bytes already match the binding.
            guard !Self.utf8Equal(text, lastSyncedText), !Self.utf8Equal(textView.string, text) else {
                lastSyncedText = text
                return
            }

            let priorSelection = textView.selectedRange()
            isSyncingFromModel = true
            pendingEditedRange = nil
            activeMarkedRange = nil
            pendingPaletteRehighlight = false
            isolatedUndoManager.removeAllActions()
            lastSyncedText = text
            if let textStorage = textView.textStorage {
                isApplyingHighlighting = true
                lastHighlightStats = highlighter.replaceText(in: textStorage, with: text, palette: currentPalette)
                isApplyingHighlighting = false
            } else {
                textView.string = text
            }

            let clamped = Self.clampedSelection(priorSelection, utf16Length: (text as NSString).length)
            textView.setSelectedRange(clamped)
            isSyncingFromModel = false
            updateTypingAttributes()
        }

        func syncExternalSelectionIfNeeded(_ selection: NSRange?) {
            guard let textView, let selection else { return }
            guard !textView.hasMarkedText() else { return }
            let clamped = Self.clampedSelection(selection, utf16Length: (textView.string as NSString).length)
            if textView.selectedRange() != clamped {
                isSyncingFromModel = true
                textView.setSelectedRange(clamped)
                isSyncingFromModel = false
                updateTypingAttributes()
            }
        }

        // MARK: - NSTextViewDelegate

        func undoManager(for view: NSTextView) -> UndoManager? {
            isolatedUndoManager
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            let deltaLength = (replacementString as NSString?)?.length ?? 0
            pendingEditedRange = NSRange(location: affectedCharRange.location, length: deltaLength)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isSyncingFromModel, let textView else { return }

            // While IME composition is active, keep marked text live in NSTextView without
            // mutating textStorage attributes or publishing provisional text to persistence/bindings.
            if textView.hasMarkedText() {
                let marked = textView.markedRange()
                if marked.location != NSNotFound {
                    activeMarkedRange = marked
                }
                return
            }

            let updatedText = textView.string
            let maxLen = (updatedText as NSString).length
            let edited = Self.mergedEditedRange(
                pending: pendingEditedRange,
                marked: activeMarkedRange,
                fallback: textView.selectedRange(),
                maxLength: maxLen
            )
            pendingEditedRange = nil
            activeMarkedRange = nil

            if pendingPaletteRehighlight {
                applyPaletteBaseAttributes(to: textView, palette: currentPalette)
                highlighter.invalidateCache()
                applyHighlighting(editedRange: nil)
                pendingPaletteRehighlight = false
            } else {
                applyHighlighting(editedRange: edited)
            }
            updateTypingAttributes()

            let changed = !Self.utf8Equal(updatedText, lastSyncedText)
            lastSyncedText = updatedText

            if !Self.utf8Equal(parent.text, updatedText) {
                parent.text = updatedText
            }
            if changed {
                parent.onTextChange?(updatedText)
            }

            let currentRange = textView.selectedRange()
            if let selectionBinding = parent.selection, selectionBinding.wrappedValue != currentRange {
                selectionBinding.wrappedValue = currentRange
            }
            attachedController?.syncStateFromHost()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isSyncingFromModel, !isApplyingHighlighting, let textView else { return }
            guard !textView.hasMarkedText() else { return }

            let currentRange = textView.selectedRange()
            updateTypingAttributes()

            if let selectionBinding = parent.selection, selectionBinding.wrappedValue != currentRange {
                selectionBinding.wrappedValue = currentRange
            }
            attachedController?.syncStateFromHost()
            parent.onSelectionChange?(currentRange)
        }

        // MARK: - Highlighting & Helpers

        private func applyPaletteBaseAttributes(to textView: MarkdownNSTextView, palette: MarkdownEditorPalette) {
            textView.font = palette.bodyFont
            textView.textColor = palette.bodyText
            textView.defaultParagraphStyle = palette.defaultParagraphStyle
        }

        private func applyHighlighting(editedRange: NSRange?) {
            guard let textView, let textStorage = textView.textStorage else { return }
            guard !textView.hasMarkedText() else { return }

            let savedSelection = textView.selectedRange()
            let marked = textView.markedRange()
            let markedOpt: NSRange? = marked.location == NSNotFound ? nil : marked

            isApplyingHighlighting = true
            lastHighlightStats = highlighter.apply(
                to: textStorage,
                palette: currentPalette,
                editedRange: editedRange,
                markedRange: markedOpt
            )
            let clamped = Self.clampedSelection(savedSelection, utf16Length: textStorage.length)
            if textView.selectedRange() != clamped {
                textView.setSelectedRange(clamped)
            }
            isApplyingHighlighting = false
        }

        private func updateTypingAttributes() {
            guard let textView, !textView.hasMarkedText() else { return }
            let location = textView.selectedRange().location
            textView.typingAttributes = highlighter.contextualTypingAttributes(
                in: textView.string,
                at: location,
                palette: currentPalette
            )
        }

        static func utf8Equal(_ lhs: String, _ rhs: String) -> Bool {
            lhs.utf8.elementsEqual(rhs.utf8)
        }

        static func mergedEditedRange(
            pending: NSRange?,
            marked: NSRange?,
            fallback: NSRange,
            maxLength: Int
        ) -> NSRange {
            let candidate: NSRange
            switch (pending, marked) {
            case let (p?, m?) where p.location != NSNotFound && m.location != NSNotFound:
                let start = min(p.location, m.location)
                let end = max(p.location + p.length, m.location + m.length)
                candidate = NSRange(location: start, length: max(0, end - start))
            case let (p?, _) where p.location != NSNotFound:
                candidate = p
            case let (_, m?) where m.location != NSNotFound:
                candidate = m
            default:
                candidate = fallback
            }
            return clampedSelection(candidate, utf16Length: maxLength)
        }

        static func clampedSelection(_ range: NSRange, utf16Length: Int) -> NSRange {
            let location = min(max(range.location, 0), max(0, utf16Length))
            let maxLength = max(0, utf16Length - location)
            let length = min(max(range.length, 0), maxLength)
            return NSRange(location: location, length: length)
        }
    }
}

// MARK: - MarkdownNSTextView

/// AppKit `NSTextView` configured specifically for plain-text raw Markdown authoring.
///
/// Exposed as `public` within `YoPDF` (and compiled into `YoPDFTests`) so unit tests can
/// directly validate TextKit 2 initialization, IME marked-text handling, native Undo/Redo,
/// selection stability, and 10,000+ word editing without launching the full GUI app.
@MainActor
public final class MarkdownNSTextView: NSTextView {
    public let activeEngine: MarkdownTextEngine
    var onEffectiveAppearanceChange: (() -> Void)?
    var onFirstResponderChange: ((Bool) -> Void)?
    var onWindowAttachment: (() -> Void)?
    var onMarkedTextEnded: ((NSRange) -> Void)?
    weak var coordinator: AnyObject?

    private let fallbackUndoManager = UndoManager()
    private var isCommittingInsertText = false

    public init(engine: MarkdownTextEngine = .textKit2) {
        let textStorage = NSTextStorage()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true

        switch engine {
        case .textKit2:
            let contentStorage = NSTextContentStorage()
            contentStorage.textStorage = textStorage
            let textLayoutManager = NSTextLayoutManager()
            contentStorage.addTextLayoutManager(textLayoutManager)
            textLayoutManager.textContainer = textContainer
            self.activeEngine = .textKit2

        case .textKit1:
            let layoutManager = NSLayoutManager()
            textStorage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(textContainer)
            self.activeEngine = .textKit1
        }

        super.init(frame: .zero, textContainer: textContainer)
        configureDefaults()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureDefaults() {
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        usesFontPanel = false
        usesRuler = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true

        // Critical: never silently mutate raw Markdown quotes, dashes (`---`), or links.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false

        isVerticallyResizable = true
        isHorizontallyResizable = false
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        autoresizingMask = [.width]
    }

    public override var undoManager: UndoManager? {
        if let delegateManager = delegate?.undoManager?(for: self) {
            return delegateManager
        }
        return fallbackUndoManager
    }

    func configureLineWrapping(_ wrapsLines: Bool, containerWidth: CGFloat) {
        isHorizontallyResizable = !wrapsLines
        autoresizingMask = wrapsLines ? [.width] : [.width, .height]
        textContainer?.widthTracksTextView = wrapsLines
        if wrapsLines {
            textContainer?.containerSize = NSSize(width: max(1, containerWidth), height: CGFloat.greatestFiniteMagnitude)
        } else {
            textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onWindowAttachment?()
        }
    }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFirstResponderChange?(true)
        }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFirstResponderChange?(false)
        }
        return resigned
    }

    public override func paste(_ sender: Any?) {
        // Always paste plain text so copied rich web/PDF fragments never inject RTF styling.
        pasteAsPlainText(sender)
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        isCommittingInsertText = true
        defer { isCommittingInsertText = false }
        super.insertText(string, replacementRange: replacementRange)
    }

    public override func unmarkText() {
        let priorMarked = markedRange()
        super.unmarkText()
        // When an IME cancels or commits via unmarkText without insertText, ensure highlighting
        // and committed-text publication catch up without leaking during insertText's internal unmark.
        if !isCommittingInsertText && !hasMarkedText() {
            onMarkedTextEnded?(priorMarked)
        }
    }
}
