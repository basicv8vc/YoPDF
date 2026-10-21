# YoPDF for macOS

Native PDF reader built with **SwiftUI + AppKit + PDFKit**. It opens local PDFs
directly from disk and renders them; there is no managed library, no network
code, no account system, and no agent integration.

P1 adds a file-first `DocumentStore` in `YoPDFCore`: file identity and version
tracking, external-change detection, and safe in-place saving.

P2a adds the first editing feature on top of it: select text, add a yellow
highlight, save, reopen. A highlight is a standard PDF `/Highlight` annotation
with `/QuadPoints`, so other readers see it as their own. Editing introduces a
minimal dirty state and a manual Save; there is no autosave or annotation sidebar
yet.

P2b extends that to editable **Highlight** and **Underline** annotations:
six presets plus a custom `ColorPicker`, click selection, recolouring, deletion,
conversion between the two subtypes, a context menu, and model-owned Undo/Redo.
Notes and strike-out remain later work.

## Requirements

- macOS 14.0 or later (deployment target)
- Xcode 16 / Swift 6 toolchain
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) —
  build-time only, never linked into the app

## Build, test, run

```bash
cd macos
./scripts/generate.sh                 # regenerate YoPDF.xcodeproj from project.yml
./scripts/build.sh                    # Debug
CONFIGURATION=Release ./scripts/build.sh
./scripts/test.sh                     # unit tests (158)
open build/DerivedData/Build/Products/Debug/YoPDF.app
```

`build.sh` and `test.sh` regenerate the Xcode project automatically when
`project.yml` is newer than the generated project, so a fresh clone only needs
XcodeGen installed.

Build products stay under `macos/build/` (git-ignored) so builds are
reproducible and easy to inspect.

`test.sh` builds with `xcodebuild build-for-testing` and then runs the bundle
with Apple's `xctest` CLI. On Xcode 26.3 / macOS 26.5.1 the `xcodebuild test`
action intermittently fails to instantiate a freshly built test bundle
(`Failed to create a bundle instance ...`) even though the same bundle runs
fine through `xctest`; see the header of `scripts/test.sh`. Set
`XCODEBUILD_TEST=1` to force the xcodebuild path when you need an `.xcresult`
or coverage data.

## Layout

```
macos/
├── project.yml                 # single source of truth for the Xcode project
├── Config/Info.plist           # bundle metadata, PDF document type
├── YoPDFCore/                  # reader logic, no UI — unit-testable module
│   ├── DocumentStore.swift     # file sessions: open/read/check/save/saveAs/close
│   ├── DocumentStoreIO.swift   # filesystem seam + POSIX implementation
│   ├── DocumentStoreError.swift
│   ├── DocumentVersion.swift   # identity, version, external-change types
│   ├── HighlightService.swift  # selection → /Highlight or /Underline
│   ├── MarkupAnnotation.swift  # kinds, palette, preferences, permissions, quads
│   ├── MarkupEditing.swift     # model-owned add/edit/delete/convert/undo
│   ├── PDFDocumentModel.swift
│   ├── PDFDocumentModel+Editing.swift # dirty state, save, Save As, re-sync
│   ├── QuitCoordinator.swift   # quit-attempt decisions, no AppKit
│   ├── ReaderViewSync.swift    # pure page/zoom decisions used by the bridge
│   └── SecurityScopeAccess.swift
├── YoPDF/
│   ├── App/YoPDFApp.swift      # @main, one model per window
│   ├── App/AppDelegate.swift   # quitting with unsaved edits
│   ├── App/QuitSession.swift   # the app-wide quit attempt
│   ├── App/WindowCloseGuard.swift # window close interception
│   ├── App/PDFReaderCommands.swift
│   ├── App/ReaderFocusedValues.swift
│   └── Reader/
│       ├── PDFViewerRepresentable.swift # PDFView ↔ SwiftUI bridge
│       ├── MarkupColorControls.swift   # presets + custom ColorPicker
│       ├── MarkupActionMenuItem.swift  # closure-backed context-menu item
│       └── PDFReaderView.swift          # toolbar, prompts, empty state
├── YoPDFTests/
│   ├── PDFFixtureFactory.swift # generates real PDFs at runtime
│   ├── SecurityScopeSpy.swift
│   ├── PDFDocumentModelTests.swift
│   ├── DocumentSecurityScopeTests.swift
│   ├── DocumentStoreTestSupport.swift   # temp dirs, payloads, fault injection
│   ├── DocumentStoreTests.swift         # sessions, versions, external changes
│   ├── DocumentStoreSaveTests.swift     # save / Save As contract
│   ├── DocumentStoreFailureTests.swift  # injected staging/commit failures
│   ├── DocumentStoreRecoveryTests.swift # partial commits, post-commit failures
│   ├── DocumentStoreSaveAsSafetyTests.swift # Save As target races and aliases
│   ├── DocumentStoreLifecycleTests.swift    # close vs. in-flight operations
│   ├── DocumentStoreScaleTests.swift    # 200 MB streaming and save
│   ├── DocumentStoreModelIntegrationTests.swift
│   ├── HighlightAnnotationTests.swift   # real PDFKit highlight geometry
│   ├── MarkupEditingTests.swift         # select, edit, undo, save integration
│   ├── DocumentEditingTests.swift       # dirty state, save outcomes, re-sync
│   ├── QuitCoordinatorTests.swift       # multi-window quit decisions
│   └── ReaderViewSyncTests.swift
└── scripts/{generate,build,test}.sh
```

Each `WindowGroup` window owns its own `PDFDocumentModel`. Menu commands read the
focused window's model through `FocusedValues`, so zoom/page actions and the open
panel apply to the active window only.

`PDFDocumentModel` does not acquire security scopes itself. It holds a
`DocumentSession`, which is the single owner of the scope for the file it opened;
closing the session (or releasing the last reference) releases the grant exactly
once. A failed open releases only the candidate session, leaving the document on
screen — and its access — untouched.

`DocumentStore` is byte-level: it never parses PDF pages and never decides what
an annotation means. A save writes a sibling staging file, flushes it, re-checks
the file's identity and content hash inside an `NSFileCoordinator` write intent,
and only then replaces the original. A changed or replaced file is reported as a
conflict instead of being overwritten.

What the save path does and does not promise:

- A detected conflict, a staging failure, and a commit that failed with the
  original verifiably still in place each leave the original bytes intact, and
  each is reported as its own error case rather than a single `saveFailed`.
- `FileManager.replaceItemAt` can fail *after* it has already started moving
  files, so a thrown error is never read as "nothing happened". The store
  re-inspects the target, the staging file and the location the system reports
  for the original; if the outcome cannot be decided it throws
  `replacementStateUncertain` listing every surviving copy. It does not delete
  the only recoverable copy and does not attempt an automatic restore — the
  caller decides.
- A replacement that succeeded but whose new version could not be read back is
  reported as `committedButUnverified`, not as a failure: the bytes *were*
  written. The session moves to `needsRefresh`, which refuses further saves until
  `refresh()` re-reads the file and re-establishes a known version.
- An error from the coordinator does not by itself mean "not committed". The
  write block can finish and install the file before the coordinator reports a
  problem, so the block's result wins, and any error that does escape is checked
  against the file's hash before it is called a failure.
- `refresh()` is not a way around the conflict check, and not a reload. On a
  session in `needsRefresh` it only accepts the bytes its save meant to write or
  the original it was told to keep; a different file at the same path — for
  instance one another program created while the outcome was undecided — leaves
  the session in `needsRefresh` and is reported as an external modification. On
  a session that is simply `.open` it refuses with `reloadRequired` rather than
  re-reading the file, because adopting a newer version there would leave the
  in-memory document holding older bytes while the save baseline moved forward.
- Crash durability is not claimed. `fsync`/`F_FULLFSYNC` is issued for the
  staging file and its directory before the replacement, but "power loss at every
  instant still leaves a consistent result" is not something these tests show.

### Highlight, dirty state and save (P2a)

A highlight is built from the `PDFView` selection in `HighlightService`:

- `PDFSelection.selectionsByLine()` gives one rectangle per line. Those
  rectangles become `/QuadPoints` on a single `/Highlight` annotation, so a
  multi-line mark paints the lines and not the empty space beside a short line.
- Each line is attributed to the page it belongs to, so a selection that spans
  pages becomes one annotation per page. A page is never annotated with geometry
  that belongs to another page.
- A selection with no text (a margin, an image, an empty drag) throws before
  anything is added. The button and the menu item use the same predicate, so they
  are never enabled for a selection that cannot produce a valid annotation.
- P2a wrote a fixed sRGB `(1, 0.8, 0)`. P2b replaced that with the `FFD60A`
  default and a configurable palette; the geometry and saving rules below are
  unchanged.

Editing is manual-save only:

- Adding a highlight marks the document edited. Nothing is written until the user
  saves, and there is no autosave.
- `PDFDocumentModel.save()` serialises the document with PDFKit and hands the
  bytes to `DocumentSession.save`. It never calls `PDFDocument.write(to:)` on the
  original path: that would bypass the version check that makes a save safe.
- A save that wrote the file and then failed to re-open it is **not** reported as
  a failed save. `SaveOutcome` distinguishes "saved", "saved but unverified"
  (with a flag for whether the edits are on disk), "conflict", "uncertain" and
  "failed". A conflict or an uncertain replacement keeps the edits in memory and
  never clears the edited flag.
- `committedButUnverified` is resolved by calling `refresh()` immediately. If the
  session can confirm the bytes it wrote, the save is a normal success; if it
  cannot, the edits stay marked unsaved and the user is told the result is
  unconfirmed.
- After a successful write the document is re-opened from the file. The
  replacement gives the file a new inode, so the `PDFDocument` that was
  memory-mapping the old one no longer describes the file the session owns.
  Re-opening is also the only end-to-end check that what was written is readable.
  The page index, the zoom and the `PDFView` instance are preserved, so saving
  does not jump back to page one.
- Closing the window, opening another document and quitting all check for unsaved
  edits first and offer Save / Don't Save / Cancel. Opening another document is
  also refused by the model itself (`LoadError.unsavedChanges`), so no caller can
  drop edits as a side effect of opening a file.
- "Don't Save" is a decision about the next document, not a promise that it will
  open. `open(url:discardingUnsavedChanges:)` only abandons the edits as part of
  the successful switch, so an open that fails leaves the old document, its
  annotations and its dirty state untouched — and the next close still asks.
- Quitting with several dirty windows is a sequence, not a broadcast. Each
  "Don't Save" is recorded in `QuitCoordinator`, tied to the document's edit
  revision, and the window stays open and dirty. The edits are only abandoned
  once the last dirty window has answered and `applicationShouldTerminate`
  returns `.terminateNow`. Cancelling any prompt clears the whole attempt, so a
  later ⌘Q asks every still-dirty window again; an edit made after a "Don't Save"
  also invalidates that answer instead of being discarded with it.
- Save As is available as the escape hatch for read-only files, hard links and
  conflicts; after it succeeds the reader continues editing the copy. Its
  failures use the same three-way split as a save: a copy that was written but
  could not be reopened is reported as "saved, not verified" (and this window
  stays on the original, still dirty), an unclassifiable replacement is reported
  as "uncertain" with the recovery files listed, and only a write that did not
  happen is reported as a failure.
- The reader has exactly one way in for a file: the toolbar, the Open panel,
  drag and drop, and `.onOpenURL` all funnel through `PDFReaderView.requestOpen`,
  which is where the unsaved-changes prompt lives. There is no second
  `.onOpenURL` handler that could open a file behind that prompt.

### Markup editing (P2b)

Highlight and Underline share one construction path. Both are standard PDF
annotations with `/QuadPoints`; a selection that spans pages is still one
annotation per page.

- **Defaults are independent.** New highlights use `#FFD60A` and new underlines
  use `#007AFF`. The values live in YoPDF's own `UserDefaults` keys,
  `dev.yopdf.markup.highlightColorHex` and
  `dev.yopdf.markup.underlineColorHex`. Choosing a colour for an existing
  annotation is a document edit and never rewrites either default.
- **Six presets and a custom colour.** The presets are `FFD60A`, `34C759`,
  `007AFF`, `FF2D55`, `AF52DE` and `FF9500`. The custom path uses SwiftUI's
  `ColorPicker` with opacity disabled. PDFKit writes `/C` as RGB and a
  save/reopen round trip discards alpha, so YoPDF stores an opaque colour;
  a fully transparent choice is rejected instead of becoming invisible.
- **Click selection uses the painted quads.** `MarkupGeometry.contains` tests
  the `/QuadPoints` rectangles, not the annotation's multi-line bounding box,
  so the empty area beside a short line does not select the mark. The selected
  quads are outlined by a view-only PDFKit page overlay; the overlay is not
  written into the PDF and does not intercept clicks.
- **One editing entry point.** `PDFDocumentModel.addMarkup`,
  `recolorSelectedMarkup`, `deleteSelectedMarkup`, `convertSelectedMarkup`,
  `undoMarkup` and `redoMarkup` are what the toolbar, menu bar and context menu
  call. There is no second mutation path in the view.
- **Undo/Redo is model-owned.** A cross-page add, delete or conversion is one
  history entry, and rapid recolours from the colour picker coalesce into one
  gesture. Every accepted edit bumps `hasUnsavedChanges` and `editRevision`;
  Undo and Redo count as edits too. A successful save or Save As reload clears
  the history and the selected annotation, because the `PDFDocument` and its
  annotation objects have been replaced. Failed, conflicting and
  uncertain-replacement saves leave the history and the selection in place. A
  committed write clears them even when the reload could not be verified: the
  bytes are on disk, so the old in-memory document is no longer the source of
  truth.
- **Permissions are checked at mutation time — including Undo/Redo.** `/F`
  ReadOnly (bit 7) and Locked (bit 8) annotations can be selected and
  inspected, but recolouring, deleting and converting them are refused. A
  context menu opened before a document switch cannot edit the old document:
  every call revalidates the annotation against the current page and document.
  Undo and Redo preflight every annotation in the entry and the document's
  commenting permission before changing anything. A protected annotation blocks
  the whole entry — including a cross-page one — without advancing
  `editRevision`, clearing the dirty state, or discarding the history; after the
  protection is removed, the same Undo/Redo is available again.
- **Conversion preserves the mark's document metadata.** Bounds, `/QuadPoints`,
  `/C`, `/Contents`, `/T`, `/NM`, `/F` and custom annotation keys are copied to
  the replacement subtype. `/AP`, `/AS`, `/Subtype` and the geometry keys are
  regenerated by PDFKit. Converting and undoing it restores the original object,
  contents and flags.
- **The context menu extends PDFKit's menu.** Right-clicking a mark selects it
  and prepends colour, convert and delete items to the standard zoom, display
  and navigation menu instead of replacing it. Colour presets and all actions
  use the same model calls as the toolbar.
- Other annotations, links and navigation are not touched. A save round trip
  preserves a square, a sticky note and a link next to an edited mark in the
  real-PDFKit tests.

Known P2a/P2b limitations:

- No annotation sidebar, no StrikeOut, note, free-text or ink annotations, and
  no annotation search. The Note work is a separate P2b PR; this PR only covers
  Highlight and Underline.
- An annotation without valid `/QuadPoints` falls back to its bounds for
  hit-testing and for the selection overlay. Every mark YoPDF creates has
  quads, but a malformed third-party one has no better geometry available.
- The selection outline is a `PDFPageOverlayViewProvider` view, not a
  `drawPagePost` drawing hook. PDFKit calls `drawPagePost` from its
  tile-rendering queue, which violates `PDFView`'s main-actor isolation and
  traps the process. Opening and rendering a document was exercised here, but
  the environment cannot drive or capture the window, so the selected-outline
  appearance after zoom/scroll, rotated pages and non-zero crop-box origins
  remain manual checks.
- Recolour coalescing uses consecutive history entries, not an explicit gesture
  boundary. Recolouring the same mark in two separate interactions can therefore
  produce one Undo entry rather than two. This is a known limitation; a later
  iteration can add begin/end gesture tracking if it proves surprising.
- Text geometry is whatever PDFKit reports. Selections over rotated pages,
  right-to-left text or unusual font encodings are not corrected here; when a
  PDFKit geometry problem is found, the sample belongs in a P3 regression set.
- PDFKit writes the system user's full name into the annotation's `/T` (author)
  entry, the same way Preview does. YoPDF does not change or suppress it yet;
  whether a highlight should carry an author at all is an open product decision.
- The window-close and quit interception is implemented on the `NSWindow`
  delegate (`WindowCloseGuard`). It owns the delegate that was installed before
  it, because `NSWindow.delegate` does not retain its delegate and replacing the
  slot would otherwise deallocate SwiftUI's and stop its teardown callbacks. It
  re-takes the slot on every view update and whenever the window becomes key or
  main, and every guard registers itself so quitting finds dirty windows even if
  the delegate slot was taken by something else. The quit decision itself —
  which window is asked next, when a temporary "Don't Save" expires, and when
  the edits may finally be abandoned — is `QuitCoordinator` in `YoPDFCore` and
  is covered by logic tests with stand-in windows. The `NSWindow` and SwiftUI
  glue around it is covered by code review only; it has **not** been exercised
  through a real window here — see the manual checklist below.
- Apple Preview interoperability was checked by inspecting the written
  annotation dictionary (`/Subtype /Highlight`, `/QuadPoints`, `/C`, `/AP`) and by
  rendering the saved file in a separate PDFKit process, not by observing
  Preview's window.

Window-level behaviour that still needs a human with a GUI session (this
environment cannot drive windows: `screencapture`, `osascript` against
System Events / Preview and `qlmanage -t` are all blocked here):

1. Highlight, then click the red close button: Save / Don't Save / Cancel each do
   what they say, and Cancel leaves the window open with the highlight intact.
2. Highlight, then ⌘W — same prompt.
3. Highlight in two windows, then ⌘Q. The app asks once per window. With A
   answering "Don't Save" and B answering "Cancel", both windows must stay open,
   A must still show its "Edited" indicator, and a second ⌘Q must ask A again.
   With both answering "Don't Save", the app quits.
4. Highlight, then open a corrupt PDF and choose "Don't Save": the corrupt file
   fails to open, and the original document is still there, still marked edited,
   still holding its highlight.
5. Select text with the mouse and click the Highlight toolbar button: moving
   focus to the button must not drop the selection before it is applied.
6. Click a highlight on the page: its painted quads get the accent outline, the
   editing controls appear in the toolbar, and a single Undo reverses the last
   add/recolour/delete/convert. Clicking the empty space inside a multi-line
   annotation's bounding box must **not** select it. Scroll and zoom while the
   mark is selected: the outline stays aligned, and text selection and
   right-click still reach PDFKit through the overlay.
7. Right-click a highlight: the colour, convert and delete items appear above
   PDFKit's zoom/display/navigation items; each action does the same thing as
   the toolbar equivalent, and the PDFKit items still work.
8. Change the Highlight and Underline swatches to different presets, quit and
   reopen the app: each tool keeps its own default. Recolouring an existing mark
   must not change either swatch.
9. Open the custom colour popover and drag through the spectrum: the annotation
   follows, one Undo returns the original colour, and the saved PDF reopens with
   the final colour.
10. Convert a highlight to an underline, undo, redo, delete and undo: the
    contents and flags set by another app survive, and saving is still a normal
    manual Save. After a successful save, Undo is disabled because the document
    was reloaded from disk.
11. Simulate a save conflict (change the file from another app) after recolouring:
    the save is refused, the annotation and the Undo history stay in the window,
    and Save As remains available.

`YoPDFCore` is a framework so tests are pure logic tests: they link the module
and never launch the app, so no window server or accessibility permission is
needed. It also keeps reader semantics independent of the SwiftUI layer, which
matters once annotations and the PDF context bridge arrive.

## Dependencies

Only Apple system frameworks: SwiftUI, AppKit, PDFKit, Foundation, Combine,
CoreTransferable, UniformTypeIdentifiers. No Swift packages, no binary
frameworks, no third-party source. `otool -L` on the Release binary reports
zero non-system libraries.

## Signing

Ad-hoc (`CODE_SIGN_IDENTITY = "-"`, no hardened runtime) so the project builds
without a developer team. Developer ID signing + notarization is a later,
separate task; see `internal/` notes (not published).

## Scope

P0 excluded annotations, search, recent documents, tabs, agent integration,
accounts, sync and PDF editing. P1 added file access and safe persistence. P2a
adds yellow highlights with a manual save. P2b makes Highlight and Underline
editable: selection, six presets plus custom colours, recolour, delete, convert
and Undo/Redo. There is still no autosave, document library, annotation sidebar,
Note/StrikeOut support or agent integration.

Known P1 boundaries:

- Security-scoped bookmarks are not created. Nothing needs to survive a window
  restoration yet, so a session holds a runtime scope only.
- Symlinks, hard links and undownloaded cloud placeholders are refused by
  `save` rather than written through; `saveAs` is the escape hatch.
- Crash durability is not claimed; the save-path notes above list exactly which
  failure outcomes are verified and which are not.
- Recovery after an undecidable save is manual by design: the session moves to
  `needsRefresh` and refuses further saves until the caller calls `refresh()`,
  and `refresh()` only succeeds when the file matches the expected outcome.
  There is no automatic retry and no background restore.
- There is no reload yet. Accepting an external change means reopening the
  document, which also replaces the in-memory PDF; `refresh()` deliberately does
  not do that, and refuses when there is no pending save to verify.
- Save As refuses to write over a target that changed, appeared or vanished
  between confirmation and the coordinated commit, and refuses aliases of the
  file the session already has open (same path via symlink, symlinked parent
  directory, or hard link). A different file with the same bytes is allowed.
- The 200 MB test skips itself when the volume has less than 800 MB free, since
  it needs room for the file plus its staging copy.
