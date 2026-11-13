//
//  MarkdownEditorTests.swift
//  YoPDFTests
//
//  Created for Task P0-C-A: Native Markdown Editor.
//  Apache-2.0 Open Source License.
//

import AppKit
import SwiftUI
import XCTest
@testable import YoPDFCore

@MainActor
final class MarkdownEditorTests: XCTestCase {

    // MARK: - Hosting Helper

    private struct HostedEditorHarness {
        let window: NSWindow
        let hostingView: NSHostingView<MarkdownEditorView>
        let textView: MarkdownNSTextView
        let controller: MarkdownEditorController
    }

    private func pumpMainRunLoop(seconds: TimeInterval = 0.03) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func findMarkdownTextView(in view: NSView) -> MarkdownNSTextView? {
        if let tv = view as? MarkdownNSTextView {
            return tv
        }
        for subview in view.subviews {
            if let found = findMarkdownTextView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func makeHostedEditor(
        initialText: String,
        configuration: MarkdownEditorConfiguration = .default,
        selection: Binding<NSRange>? = nil,
        onTextChange: ((String) -> Void)? = nil
    ) -> HostedEditorHarness {
        var backingText = initialText
        let textBinding = Binding<String>(
            get: { backingText },
            set: { backingText = $0 }
        )
        let controller = MarkdownEditorController()
        let view = MarkdownEditorView(
            text: textBinding,
            selection: selection,
            configuration: configuration,
            controller: controller,
            onTextChange: onTextChange
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 540)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        pumpMainRunLoop()

        guard let textView = findMarkdownTextView(in: hostingView) else {
            fatalError("Expected MarkdownNSTextView inside NSHostingView")
        }
        return HostedEditorHarness(
            window: window,
            hostingView: hostingView,
            textView: textView,
            controller: controller
        )
    }

    // MARK: - 1. Source Round-Trip & Authoritative Preservation

    func testSourceRoundTripPreservesFrontmatterLinksTablesCodeFencesAndWhitespace() {
        let original = """
        ---
        title: "Paper Notes — \"Exact\" Quotes & -- Dashes"
        authors:
          - Alice
          - Bob
        ---

        # Heading 1

        Paragraph with trailing spaces  
        \tIndented with tab and emoji 🧪 and CJK 中文日本語.

        See [Vaswani et al., p. 5](./attention.pdf#page=5) and <https://example.com>.

        | Column A | Column B |
        | :--- | ---: |
        | `foo_bar_baz` | **bold** & ~~strike~~ |

        ```python
        def f(x):
            return "--not-an-emdash--"
        ```

        ~~~
        tilde fence preserved
        ~~~
        """

        let harness = makeHostedEditor(initialText: original)
        XCTAssertEqual(harness.textView.string, original)
        XCTAssertEqual(harness.textView.textStorage?.string, original)

        // Highlight again in Dark theme and verify zero character mutation.
        let darkPalette = MarkdownEditorPalette(isDark: true)
        let highlighter = MarkdownSyntaxHighlighter()
        highlighter.apply(to: harness.textView.textStorage!, palette: darkPalette)
        XCTAssertEqual(harness.textView.string, original)
        XCTAssertEqual(harness.textView.textStorage?.string, original)

        // Verify destructive smart substitutions are disabled.
        XCTAssertFalse(harness.textView.isRichText)
        XCTAssertFalse(harness.textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(harness.textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(harness.textView.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(harness.textView.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(harness.textView.isAutomaticSpellingCorrectionEnabled)
    }

    func testCRLFAndTrailingBlankLinesArePreserved() {
        let crlfSource = "---\r\ntitle: CRLF\r\n---\r\n\r\nLine 1  \r\nLine 2\r\n\r\n"
        let harness = makeHostedEditor(initialText: crlfSource)
        XCTAssertEqual(harness.textView.string, crlfSource)
    }

    // MARK: - 2. TextKit 2 Feasibility & Engine Selection

    func testTextKit2IsActiveByDefaultAndTextKit1FallbackWorks() {
        let tk2TextView = MarkdownNSTextView(engine: .textKit2)
        XCTAssertEqual(tk2TextView.activeEngine, .textKit2)
        XCTAssertNotNil(tk2TextView.textLayoutManager)

        let harness = makeHostedEditor(initialText: "# TextKit 2 Check\n\nBody text.")
        XCTAssertEqual(harness.controller.activeEngine, .textKit2)
        XCTAssertNotNil(harness.textView.textLayoutManager)

        let tk1TextView = MarkdownNSTextView(engine: .textKit1)
        XCTAssertEqual(tk1TextView.activeEngine, .textKit1)
        XCTAssertNotNil(tk1TextView.layoutManager)
    }

    // MARK: - 3. Syntax Highlighting, Monospace Code & Themes

    func testSyntaxScannerDetectsMarkdownConstructsWithoutIntrawordUnderscoreFalsePositives() {
        let sample = """
        ---
        key: value
        ---

        # Title
        Text with `inline_code`, snake_case_identifier, _italic_, **bold**, ~~old~~, and [link](./a.pdf#page=2).

        > Quote line
        - [x] Done task

        | Col1 | Col2 |
        | --- | --- |
        | A | B |

        ```swift
        let x = 1
        ```
        """

        let spans = MarkdownSyntaxHighlighter.scanSpans(in: sample)
        let nsSample = sample as NSString

        let kinds = spans.map(\.kind)
        XCTAssertTrue(kinds.contains(.frontmatterDelimiter))
        XCTAssertTrue(kinds.contains(.frontmatterKey))
        XCTAssertTrue(kinds.contains(.heading(level: 1)))
        XCTAssertTrue(kinds.contains(.inlineCode))
        XCTAssertTrue(kinds.contains(.bold))
        XCTAssertTrue(kinds.contains(.italic))
        XCTAssertTrue(kinds.contains(.strikethrough))
        XCTAssertTrue(kinds.contains(.linkText))
        XCTAssertTrue(kinds.contains(.linkURL))
        XCTAssertTrue(kinds.contains(.blockquoteMarker))
        XCTAssertTrue(kinds.contains(.listMarker))
        XCTAssertTrue(kinds.contains(.taskCheckbox))
        XCTAssertTrue(kinds.contains(.tableDelimiter))
        XCTAssertTrue(kinds.contains(.codeBlockFence))
        XCTAssertTrue(kinds.contains(.codeBlockLanguage))
        XCTAssertTrue(kinds.contains(.codeBlock))

        // `snake_case_identifier` must NOT produce an `.italic` span for `_case_`.
        let italicTexts = spans
            .filter { $0.kind == .italic }
            .map { nsSample.substring(with: $0.range) }
        XCTAssertEqual(italicTexts, ["italic"])
    }

    func testMonospaceFontAppliedToCodeBlocksInlineCodeAndTables() {
        let source = """
        Prose text.

        Inline `mono()` here.

        | H1 | H2 |
        | --- | --- |
        | v1 | v2 |

        ```swift
        let code = true
        ```
        """
        let harness = makeHostedEditor(initialText: source)
        let storage = harness.textView.textStorage!
        let nsSource = source as NSString

        let proseLoc = nsSource.range(of: "Prose").location
        let inlineLoc = nsSource.range(of: "mono()").location
        let tableLoc = nsSource.range(of: "v1").location
        let codeLoc = nsSource.range(of: "let code").location

        let proseFont = storage.attribute(.font, at: proseLoc, effectiveRange: nil) as? NSFont
        let inlineFont = storage.attribute(.font, at: inlineLoc, effectiveRange: nil) as? NSFont
        let tableFont = storage.attribute(.font, at: tableLoc, effectiveRange: nil) as? NSFont
        let codeFont = storage.attribute(.font, at: codeLoc, effectiveRange: nil) as? NSFont

        XCTAssertNotNil(proseFont)
        XCTAssertFalse(proseFont?.isFixedPitch ?? true)
        XCTAssertTrue(inlineFont?.isFixedPitch ?? false)
        XCTAssertTrue(tableFont?.isFixedPitch ?? false)
        XCTAssertTrue(codeFont?.isFixedPitch ?? false)
    }

    func testLightAndDarkThemesProduceDistinctColors() {
        let light = MarkdownEditorPalette.resolved(theme: .light, appearance: nil, fontSize: 14, lineHeightMultiple: 1.45)
        let dark = MarkdownEditorPalette.resolved(theme: .dark, appearance: nil, fontSize: 14, lineHeightMultiple: 1.45)

        XCTAssertFalse(light.isDark)
        XCTAssertTrue(dark.isDark)
        XCTAssertNotEqual(light.editorBackground, dark.editorBackground)
        XCTAssertNotEqual(light.bodyText, dark.bodyText)

        let lightHarness = makeHostedEditor(
            initialText: "# Heading",
            configuration: MarkdownEditorConfiguration(theme: .light)
        )
        let darkHarness = makeHostedEditor(
            initialText: "# Heading",
            configuration: MarkdownEditorConfiguration(theme: .dark)
        )
        XCTAssertEqual(lightHarness.textView.backgroundColor, light.editorBackground)
        XCTAssertEqual(darkHarness.textView.backgroundColor, dark.editorBackground)
    }

    // MARK: - 4. Native Undo/Redo & Pane Isolation

    func testNativeUndoAndRedoRoundTripAndPaneIsolation() {
        var latestA = "Initial"
        let harnessA = makeHostedEditor(
            initialText: latestA,
            onTextChange: { latestA = $0 }
        )
        let harnessB = makeHostedEditor(initialText: "Other Pane")

        harnessA.controller.setSelection(NSRange(location: 7, length: 0))
        XCTAssertTrue(harnessA.controller.insertText("\n\n- Added item"))
        XCTAssertEqual(harnessA.textView.string, "Initial\n\n- Added item")
        XCTAssertEqual(latestA, "Initial\n\n- Added item")
        XCTAssertTrue(harnessA.controller.canUndo)
        XCTAssertFalse(harnessB.controller.canUndo, "Undo stack must be isolated per editor instance")

        XCTAssertTrue(harnessA.controller.undo())
        XCTAssertEqual(harnessA.textView.string, "Initial")
        XCTAssertEqual(latestA, "Initial")
        XCTAssertTrue(harnessA.controller.canRedo)

        XCTAssertTrue(harnessA.controller.redo())
        XCTAssertEqual(harnessA.textView.string, "Initial\n\n- Added item")
        XCTAssertEqual(latestA, "Initial\n\n- Added item")
    }

    // MARK: - 5. Selection Stability & Focus Restoration

    func testSelectionClampingAndPreservationAcrossHighlightAndFocusRestore() {
        let initial = "# Header\n\nEmoji 🧪 and 中文 text.\n"
        var observedSelection = NSRange(location: 0, length: 0)
        let selectionBinding = Binding<NSRange>(
            get: { observedSelection },
            set: { observedSelection = $0 }
        )

        let harness = makeHostedEditor(initialText: initial, selection: selectionBinding)

        // Set selection inside CJK text.
        let targetRange = (initial as NSString).range(of: "中文")
        harness.controller.setSelection(targetRange)
        XCTAssertEqual(harness.textView.selectedRange(), targetRange)
        XCTAssertEqual(observedSelection, targetRange)

        // Re-highlighting via appearance change must preserve selection.
        harness.textView.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(harness.textView.selectedRange(), targetRange)

        // Out-of-bounds selection must clamp safely without NSRangeException.
        harness.controller.setSelection(NSRange(location: 99_999, length: 500))
        XCTAssertEqual(harness.textView.selectedRange(), NSRange(location: (initial as NSString).length, length: 0))

        // Queued focus & selection restoration before window attachment.
        let detachedController = MarkdownEditorController()
        detachedController.focus(restoringSelection: targetRange)
        XCTAssertTrue(detachedController.pendingFocusRequest)
        XCTAssertEqual(detachedController.pendingSelection, targetRange)

        let reattachedView = MarkdownEditorView(
            text: .constant(initial),
            controller: detachedController
        )
        let host = NSHostingView(rootView: reattachedView)
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.contentView = host
        win.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        pumpMainRunLoop()

        XCTAssertEqual(detachedController.selectedRange, targetRange)
    }

    // MARK: - 6. Chinese & Japanese IME Composition (NSTextInputClient)

    func testChineseAndJapaneseIMECompositionIsPreservedAndCommittedCleanly() {
        var reportedText = "# Note\n\n"
        let harness = makeHostedEditor(
            initialText: reportedText,
            onTextChange: { reportedText = $0 }
        )
        let endLocation = (reportedText as NSString).length
        harness.controller.setSelection(NSRange(location: endLocation, length: 0))

        // 1. Chinese Pinyin preedit (`setMarkedText`)
        harness.textView.setMarkedText(
            "zhongwen",
            selectedRange: NSRange(location: 8, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(harness.textView.hasMarkedText())
        XCTAssertEqual(harness.textView.markedRange(), NSRange(location: endLocation, length: 8))

        // Even if highlighting is invoked while marked text is active, it must skip without clearing markedRange.
        let statsWhileMarked = MarkdownSyntaxHighlighter().apply(
            to: harness.textView.textStorage!,
            palette: MarkdownEditorPalette(isDark: false),
            editedRange: NSRange(location: endLocation, length: 8),
            markedRange: harness.textView.markedRange()
        )
        XCTAssertTrue(statsWhileMarked.skippedForMarkedText)
        XCTAssertTrue(harness.textView.hasMarkedText())

        // 2. Candidate selection commits Chinese characters via `insertText(_:replacementRange:)`.
        harness.textView.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(harness.textView.hasMarkedText())
        XCTAssertEqual(harness.textView.string, "# Note\n\n中文")
        XCTAssertEqual(reportedText, "# Note\n\n中文")

        // Separate distinct IME composition bursts across event-loop turns.
        harness.textView.breakUndoCoalescing()
        pumpMainRunLoop(seconds: 0.01)

        // 3. Japanese Kana preedit + `unmarkText` commit.
        let jpStart = (harness.textView.string as NSString).length
        harness.textView.setMarkedText(
            "日本語",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(harness.textView.hasMarkedText())
        XCTAssertEqual(harness.textView.markedRange(), NSRange(location: jpStart, length: 3))

        harness.textView.unmarkText()
        XCTAssertFalse(harness.textView.hasMarkedText())
        XCTAssertEqual(harness.textView.string, "# Note\n\n中文日本語")
        XCTAssertEqual(reportedText, "# Note\n\n中文日本語")
        harness.textView.breakUndoCoalescing()
        pumpMainRunLoop(seconds: 0.01)

        // 4. Undo reverses the committed Japanese text cleanly, then the Chinese text.
        XCTAssertTrue(harness.controller.undo())
        XCTAssertEqual(harness.textView.string, "# Note\n\n中文")
        XCTAssertEqual(reportedText, "# Note\n\n中文")
        XCTAssertTrue(harness.controller.undo())
        XCTAssertEqual(harness.textView.string, "# Note\n\n")
    }

    // MARK: - 7. Large Document (10,000+ Words) & Incremental Highlight Performance

    func testLargeDocument10kPlusWordsIncrementalEditingIsFastAndAccurate() {
        let largeDoc = MarkdownEditorDemoView.largeStressNote(wordTarget: 12_000)
        let wordCount = largeDoc.split(whereSeparator: { $0.isWhitespace }).count
        XCTAssertGreaterThanOrEqual(wordCount, 10_000)

        // 1. TextKit 2 hosted benchmark
        let loadStart = CFAbsoluteTimeGetCurrent()
        let harness = makeHostedEditor(initialText: largeDoc)
        let loadElapsedMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000.0

        XCTAssertEqual(harness.textView.string, largeDoc)
        XCTAssertEqual(harness.controller.lastHighlightStats?.wasFullHighlight, true)

        // Single-line edit near the start (visible viewport) and 5 consecutive keystrokes near the middle.
        harness.controller.setSelection(NSRange(location: 120, length: 0), scrollToVisible: false)
        let topEditStart = CFAbsoluteTimeGetCurrent()
        XCTAssertTrue(harness.controller.insertText(" [top-edit]"))
        let topEditMs = (CFAbsoluteTimeGetCurrent() - topEditStart) * 1000.0

        let middleLocation = (harness.textView.string as NSString).length / 2
        harness.controller.setSelection(NSRange(location: middleLocation, length: 0), scrollToVisible: false)
        let midEditStart = CFAbsoluteTimeGetCurrent()
        for ch in ["a", "b", "c", "d", "e"] {
            XCTAssertTrue(harness.controller.insertText(ch))
        }
        let midEditAvgMs = ((CFAbsoluteTimeGetCurrent() - midEditStart) * 1000.0) / 5.0

        let stats = harness.controller.lastHighlightStats
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.wasFullHighlight, false)
        XCTAssertLessThanOrEqual(stats?.updatedLines ?? Int.max, 4, "Incremental edit must only re-highlight nearby lines")

        // 2. TextKit 1 comparison benchmark
        let tk1LoadStart = CFAbsoluteTimeGetCurrent()
        let tk1Harness = makeHostedEditor(
            initialText: largeDoc,
            configuration: MarkdownEditorConfiguration(preferredEngine: .textKit1)
        )
        let tk1LoadMs = (CFAbsoluteTimeGetCurrent() - tk1LoadStart) * 1000.0
        tk1Harness.controller.setSelection(NSRange(location: 120, length: 0), scrollToVisible: false)
        let tk1TopStart = CFAbsoluteTimeGetCurrent()
        XCTAssertTrue(tk1Harness.controller.insertText(" [top-edit]"))
        let tk1TopMs = (CFAbsoluteTimeGetCurrent() - tk1TopStart) * 1000.0

        let tk1MidLoc = (tk1Harness.textView.string as NSString).length / 2
        tk1Harness.controller.setSelection(NSRange(location: tk1MidLoc, length: 0), scrollToVisible: false)
        let tk1MidStart = CFAbsoluteTimeGetCurrent()
        for ch in ["a", "b", "c", "d", "e"] {
            XCTAssertTrue(tk1Harness.controller.insertText(ch))
        }
        let tk1MidAvgMs = ((CFAbsoluteTimeGetCurrent() - tk1MidStart) * 1000.0) / 5.0

        print(String(format: "[markdown-scale] words=%d utf16=%d TK2(load=%.2fms topEdit=%.2fms midAvg=%.2fms) TK1(load=%.2fms topEdit=%.2fms midAvg=%.2fms) updatedLines=%d/%d",
                     wordCount,
                     (largeDoc as NSString).length,
                     loadElapsedMs,
                     topEditMs,
                     midEditAvgMs,
                     tk1LoadMs,
                     tk1TopMs,
                     tk1MidAvgMs,
                     stats?.updatedLines ?? -1,
                     stats?.totalLines ?? -1))

        XCTAssertLessThan(midEditAvgMs, 100.0, "Incremental typing on 12k words should average under 100ms (got \(midEditAvgMs)ms)")
    }

    func testOpeningAndClosingCodeFenceUpdatesSubsequentLinesIncrementally() {
        let initial = """
        # Top

        Line 1
        Line 2
        Line 3
        """
        let harness = makeHostedEditor(initialText: initial)
        let storage = harness.textView.textStorage!
        let line2Before = (harness.textView.string as NSString).range(of: "Line 2").location
        let fontBefore = storage.attribute(.font, at: line2Before, effectiveRange: nil) as? NSFont
        XCTAssertFalse(fontBefore?.isFixedPitch ?? true)

        // Insert opening fence before Line 1.
        let insertLoc = (harness.textView.string as NSString).range(of: "Line 1").location
        harness.controller.setSelection(NSRange(location: insertLoc, length: 0), scrollToVisible: false)
        XCTAssertTrue(harness.controller.insertText("```swift\n"))

        let line2AfterOpen = (harness.textView.string as NSString).range(of: "Line 2").location
        let fontInsideFence = storage.attribute(.font, at: line2AfterOpen, effectiveRange: nil) as? NSFont
        XCTAssertTrue(fontInsideFence?.isFixedPitch ?? false)

        // Close the fence before Line 2 -> Line 2 returns to proportional prose font.
        harness.controller.setSelection(NSRange(location: line2AfterOpen, length: 0), scrollToVisible: false)
        XCTAssertTrue(harness.controller.insertText("```\n"))

        let line2AfterClose = (harness.textView.string as NSString).range(of: "Line 2").location
        let fontAfterClose = storage.attribute(.font, at: line2AfterClose, effectiveRange: nil) as? NSFont
        XCTAssertFalse(fontAfterClose?.isFixedPitch ?? true)
    }

    // MARK: - 8. Multiline Cursor Movement, Selection, Plain-Text Paste & Demo View

    func testMultilineCursorMovementAndSelectionAndPlainTextPasteFromPrivatePasteboard() {
        let initial = "First line\nSecond line\nThird line"
        let harness = makeHostedEditor(initialText: initial)

        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
        harness.textView.moveDown(nil)
        let secondLineStart = ("First line\n" as NSString).length
        XCTAssertEqual(harness.textView.selectedRange().location, secondLineStart)

        harness.textView.selectAll(nil)
        XCTAssertEqual(harness.textView.selectedRange(), NSRange(location: 0, length: (initial as NSString).length))

        // Insert multiline newline via native responder command.
        harness.textView.setSelectedRange(NSRange(location: secondLineStart, length: 0))
        harness.textView.insertNewline(nil)
        XCTAssertEqual(harness.textView.string, "First line\n\nSecond line\nThird line")

        // Verify reading rich attributed string from an isolated pasteboard drops RTF attributes and inserts plain text.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let rich = NSAttributedString(
            string: "**pasted**",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 28), .foregroundColor: NSColor.systemRed]
        )
        pasteboard.clearContents()
        pasteboard.writeObjects([rich])

        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(harness.textView.readSelection(from: pasteboard, type: .string))
        XCTAssertTrue(harness.textView.string.hasPrefix("**pasted**First line"))
    }

    func testMarkdownEditorDemoViewHostsCleanlyInLightAndDark() {
        for theme in [MarkdownColorTheme.light, MarkdownColorTheme.dark] {
            let demo = MarkdownEditorDemoView(initialTheme: theme)
            let hosting = NSHostingView(rootView: demo)
            hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            pumpMainRunLoop()
            XCTAssertNotNil(findMarkdownTextView(in: hosting))
        }
    }
}
