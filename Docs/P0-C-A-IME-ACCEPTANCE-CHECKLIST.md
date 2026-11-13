# YoPDF P0-C-A — Manual IME & Interactive UI Acceptance Checklist

Automated unit tests (`YoPDFTests/MarkdownEditorTests.swift`) verify `NSTextInputClient` marked-text preservation (`setMarkedText`, `markedRange`, `insertText`, `unmarkText`), TextKit 2 initialization, source round-trip, Undo/Redo, selection clamping, and 12,000+ word incremental highlighting.

The items below require an interactive logged-in macOS GUI session (with real macOS Chinese/Japanese input sources and Xcode Canvas / app window) and are **not** claimed as verified by headless unit tests.

## 1. Chinese IME (Pinyin — Simplified / Traditional)

1. Open `MarkdownEditorDemoView` (Xcode Preview or embedded host).
2. Switch macOS input source to **Pinyin - Simplified** (or Traditional).
3. Type a multi-syllable phrase (e.g., `yopdfbijiben` / `nihaoshijie`) in a plain paragraph:
   - Confirm the marked text underline and segmented clauses appear cleanly without flicker.
   - Confirm the macOS candidate bar is positioned right below/beside the active caret (including on lines with larger `# Heading` fonts and on lines inside fenced ` ``` ` code blocks).
4. Press `Space` / `1`–`9` to select a candidate:
   - Confirm the committed Chinese text appears once (no duplicated preedit characters).
   - Confirm `⌘Z` undoes the committed Chinese phrase cleanly and `⇧⌘Z` redoes it.
5. Type Pinyin mid-composition and press `Esc` (cancel) or click elsewhere in the note:
   - Confirm composition cancels or commits gracefully without corrupting syntax highlighting or shifting the cursor.
6. Type Chinese inside:
   - A `# Heading` line
   - A `**bold**` or `[link](./paper.pdf#page=5)` span
   - A GFM pipe table cell (`| 列1 | 列2 |`)
   - A fenced code block (` ```python `)
   - Confirm candidate window positioning and monospaced/heading font consistency in each context.

## 2. Japanese IME (Romaji / Kana)

1. Switch macOS input source to **Japanese - Romaji** (or Kana).
2. Type `nihongono` and press `Space` repeatedly to cycle conversion candidates (`日本語の` / `日本語ノ`):
   - Confirm candidate cycling updates the marked text cleanly without losing focus or resetting scroll position.
   - Confirm pressing `Left`/`Right` arrow keys during clause adjustment resizes clauses normally (`NSMarkedClauseSegment`).
3. Press `Return` to commit:
   - Confirm committed text matches the selected candidate and syntax highlighting updates immediately.
   - Confirm `⌘Z` undoes the committed phrase cleanly.

## 3. Interactive Editing, Scroll & Theme Checks

1. Load the **10k Words** stress sample in `MarkdownEditorDemoView` and scroll rapidly from top to bottom with a trackpad:
   - Confirm smooth 60/120 Hz scrolling with no layout height jumps or blank frames.
2. Type rapidly at the top, middle, and bottom of the 10k-word note:
   - Confirm zero perceptible typing lag and steady scroll position.
3. Toggle **System / Light / Dark** themes and macOS Appearance (System Settings → Appearance → Light/Dark):
   - Confirm background, text, code blocks, syntax markers, and insertion point update immediately without resetting cursor or Undo history.
4. Copy rich styled text from Safari or Apple Notes and paste (`⌘V`) into `MarkdownEditorView`:
   - Confirm plain text is pasted without injecting external RTF fonts or colors.
5. Note on `⌘Z` / `⇧⌘Z` integration for P0-C-C (Agent C):
   - Currently `PDFReaderCommands.swift` defines `CommandGroup(replacing: .undoRedo)` bound to `PDFDocumentModel.undoMarkup()` / `redoMarkup()`. When Agent C integrates `MarkdownEditorView` into `WorkspaceWindowModel` / `PDFReaderView`, command routing must dispatch `⌘Z` / `⇧⌘Z` to the active pane's `MarkdownEditorController` when a Markdown pane is focused.
