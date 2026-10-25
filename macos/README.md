# YoPDF for macOS

Native PDF reader built with **SwiftUI + AppKit + PDFKit**. It opens local PDFs
directly from disk and renders them; there is no managed library, no network
code, no account system, and no agent integration.

P1 adds a file-first `DocumentStore` in `YoPDFCore`: file identity and version
tracking, external-change detection, and safe in-place saving.

P2a adds the first editing feature on top of it: select text, add a yellow
highlight, save, reopen. A highlight is a standard PDF `/Highlight` annotation
with `/QuadPoints`, so other readers see it as their own. Editing introduced a
minimal dirty state and a manual Save; committed annotation edits now auto-save
after a short quiet period.

P2b extends that to editable **Highlight** and **Underline** annotations:
six presets plus a custom `ColorPicker`, click selection, recolouring, deletion,
conversion between the two subtypes, a context menu, and model-owned Undo/Redo.

P2c adds **notes**: a compact SwiftUI composer writes a standard PDF `/Text`
annotation, either about the selected text or at a point the user clicks on the
page. Six paper tints, a marker drawn over the page, editing, deletion and
Undo/Redo all go through the same model pipeline as Highlight and Underline.
Committed annotation edits auto-save after a short quiet period; a note draft
remains in the composer until the user saves it into the PDF.

P2d adds the first **sticker** stage: the 20 original ShuaMac illustrations are
packaged in an Asset Catalog, and a note's motif, paper palette, template title
and SF Symbol persist in a versioned `/YoPDFNoteStyle` value (v2; a v1 value
still reads). The marker position is a CropBox-relative anchor because PDFKit
rewrites a `/Text` annotation's `/Rect` on the first save. The composer follows
ShuaMac's compact layout: a 32pt sticker face, a template menu with the twelve
built-in outlines plus a personal template library, and an expandable sheet
editor. ShuaMac thought groups imported from PDF show one sticker with a count
badge. Legacy stacks that lost their group ID are recognized when same-style,
24pt Shua note rectangles form a continuous 23pt vertical stack. Dragging a
group marker moves its member notes together. Editing individual thoughts
within a group remains a later stage.

P2e adds a native, collapsible reading sidebar with the PDF's own outline,
PDFKit page thumbnails, and an index of standard PDF annotations. The thumbnail
view stays connected to the reader, outline destinations keep their target
position, and annotation rows jump to their page location. The sidebar belongs
to the open document window; it does not manage files or create a PDF library.

## Recent Documents and reading position

The File menu's **Open Recent** list and the empty reader window make the last
10 PDFs easy to find. The app stores one versioned property list in
`UserDefaults`; each entry contains a security-scoped bookmark, a display name,
and the last page and zoom mode. This is a small preference value, not a
document database or managed library.

Opening a recent item resolves its bookmark and then uses the normal
`DocumentStore` path, which acquires and holds the security scope for the open
window. Stale bookmarks are refreshed after that session has acquired access.
The reader saves the current page and either Fit mode or the manual zoom factor
as navigation changes. Reopened page indices are clamped to the PDF's current
page count; Fit is recalculated for the current window size. Recent items still
go through the usual unsaved-document and note-draft prompts. YoPDF does not
automatically reopen every window at launch.

If macOS can no longer resolve a saved bookmark, YoPDF keeps the recent entry
and offers **Relink…**. Choosing the moved PDF validates and opens it before
YoPDF replaces that entry's bookmark and path. The entry keeps its identity and
reading position, and any duplicate for the selected path is removed. Canceling
the picker or choosing a file that cannot be opened leaves the recent entry
unchanged.

## Full-text PDF search

P3 adds **full-text PDF search**. Press ⌘F to open the find bar, type a literal
phrase, and use the result count and previous/next controls to move through the
matches. Search is case-insensitive and highlights every match on the pages;
Return or ⌘G moves forward, ⇧⌘G moves backward, and results wrap at either end.
Esc closes the find bar and removes the temporary search highlights. The
search covers text extractable by PDFKit; image-only scans require OCR and are
not included. Search uses PDFKit and does not require network access.

The File menu's **Export Annotations as Markdown…** writes a local `.md` reading
log grouped by page. It includes Highlight and Underline text, Note excerpts and
bodies, and comments attached to markup annotations. Plain annotation text is
escaped as Markdown text; unsupported annotation types are omitted. Markups
whose text cannot be extracted remain visible with a placeholder. Exporting
does not modify the PDF.

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
./scripts/test.sh                     # unit tests (359)
./scripts/test-ui.sh                  # GUI tests (interactive logged-in desktop session)
open build/DerivedData/Build/Products/Debug/YoPDF.app
```

`build.sh` and `test.sh` regenerate the Xcode project automatically when
`project.yml` is newer than the generated project, so a fresh clone only needs
XcodeGen installed.

Build products stay under `macos/build/` (git-ignored) so builds are
reproducible and easy to inspect.

## Sparkle updates

The macOS app links Sparkle 2.10.0. It checks the configured signed appcast on
Sparkle's normal schedule and adds **Check for Updates…** to the YoPDF menu.
Scheduled update alerts are represented by a small native titlebar indicator
in each open PDF window; clicking it opens Sparkle's standard update dialog.
Dismiss keeps the reminder available, while installing or skipping clears it.
Sparkle downloads an update only after the user chooses to install it. Both
`SUAutomaticallyUpdate` and
`SUAllowsAutomaticUpdates` are false, so Sparkle cannot install an update
automatically.

An updater starts only when the app is built with both `SPARKLE_FEED_URL` (an
HTTPS appcast URL) and `SPARKLE_PUBLIC_ED_KEY` (the Base64 EdDSA public key).
The build script forwards these optional environment variables to Xcode; when
they are missing or invalid, update checks stay disabled. Set the real values
in the release environment before running
`CONFIGURATION=Release ./scripts/build.sh`. The feed and update archives must
be signed with the matching private key. Keep that key in a secure developer
key store; never add it to the repository or pass it to the build.

A Debug build can preview the titlebar indicator without a feed by launching
with `--yopdf-preview-update=99.0.0`. The indicator remains disabled until
Sparkle reports that an update check can start.

YoPDF currently has no production appcast or Sparkle key configured. Its
existing ad-hoc signing setup is for local development; public distribution
still needs Developer ID signing and notarization.

`test.sh` builds with `xcodebuild build-for-testing` and then runs the bundle
with Apple's `xctest` CLI. On Xcode 26.3 / macOS 26.5.1 the `xcodebuild test`
action intermittently fails to instantiate a freshly built test bundle
(`Failed to create a bundle instance ...`) even though the same bundle runs
fine through `xctest`; see the header of `scripts/test.sh`. Set
`XCODEBUILD_TEST=1` to force the xcodebuild path when you need an `.xcresult`
or coverage data. This path filters to `YoPDFTests`, so it remains usable
without a desktop session; run `test-ui.sh` separately for GUI tests.

`test-ui.sh` runs `YoPDFUITests` through Xcode's UI testing runner. It launches
the built app and sends real keyboard input, so it requires an interactive,
logged-in macOS desktop session. The UI regression tests use PDFs generated in
temporary directories and remove them after each test.

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
│   ├── NoteAnnotation.swift    # /Text notes, style keys, anchors, markers
│   ├── NoteStickerStyle.swift  # 21 motif IDs, collections, versioned style
│   ├── NoteEditing.swift       # model-owned add/edit/delete notes
│   ├── PDFDocumentModel.swift
│   ├── RecentDocumentsStore.swift # bookmarks and reading positions in UserDefaults
│   ├── PDFDocumentModel+Editing.swift # dirty state, save, Save As, re-sync
│   ├── PDFDocumentSaveSerializer.swift # isolated PDF snapshot serialization
│   ├── QuitCoordinator.swift   # quit-attempt decisions, no AppKit
│   ├── ReaderViewSync.swift    # pure page/zoom decisions used by the bridge
│   └── SecurityScopeAccess.swift
├── YoPDF/
│   ├── Resources/Assets.xcassets # AppIcon + 20 sticker imagesets + metadata
│   ├── App/YoPDFApp.swift      # @main, one model per window
│   ├── App/AppDelegate.swift   # quitting with unsaved edits
│   ├── App/QuitSession.swift   # the app-wide quit attempt
│   ├── App/WindowCloseGuard.swift # window close interception
│   ├── App/PDFReaderCommands.swift
│   ├── App/ReaderFocusedValues.swift
│   └── Reader/
│       ├── PDFViewerRepresentable.swift # PDFView ↔ SwiftUI bridge
│       ├── ReaderSidebar.swift          # outline, thumbnails and annotation index
│       ├── NoteComposer.swift          # compact note popover and paper tints
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
│   ├── AutoSaveTests.swift               # debounce, undo, failures and responsiveness
│   ├── DocumentStoreLifecycleTests.swift    # close vs. in-flight operations
│   ├── DocumentStoreScaleTests.swift    # 200 MB streaming and save
│   ├── DocumentStoreModelIntegrationTests.swift
│   ├── RecentDocumentsStoreTests.swift # bookmarks and page/zoom restoration
│   ├── HighlightAnnotationTests.swift   # real PDFKit highlight geometry
│   ├── MarkupEditingTests.swift         # select, edit, undo, save integration
│   ├── NoteAnnotationTests.swift        # real PDFKit /Text notes end to end
│   ├── NoteStickerStyleTests.swift      # sticker style, anchors, assets, drafts
│   ├── DocumentEditingTests.swift       # dirty state, save outcomes, re-sync
│   ├── QuitCoordinatorTests.swift       # multi-window quit decisions
│   ├── QuitDraftDeferralTests.swift     # deferred draft discard across a quit
│   └── ReaderViewSyncTests.swift
└── scripts/{generate,build,test,verify-sticker-assets}.sh
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

Committed annotation edits are automatically saved after 750 milliseconds
without another edit. The pending interval is reset while a change is still in
progress, so a marker drag or colour-picker gesture is written as one update.
Note composer text is a draft and is not written until the user commits the
note. ⌘S and the Save button remain available for an immediate save.

- Adding or editing a highlight, underline or note marks the document edited and
  schedules an automatic save through the open `DocumentSession`.
- Automatic saving copies the live `PDFDocument` on the main actor, then uses a
  private snapshot on a utility worker for Shua metadata preservation, PDF
  serialization, the coordinated `DocumentSession` write and reopen check. The
  displayed document and its annotation objects stay in place for Undo and Redo.
- The Save As panel pauses a pending 750 ms debounce. Cancelling the panel
  resumes automatic saving; choosing a destination cancels that checkpoint and
  writes the current edits to the copy, leaving the source unchanged. If an
  automatic save has already entered `DocumentSession.save`, it completes first;
  Save As then writes the same edits to the destination.
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
- After a successful manual write the document is re-opened from the file. The
  replacement gives the file a new inode, so the `PDFDocument` that was
  memory-mapping the old one no longer describes the file the session owns.
  Automatic saves also reopen the file to verify it is readable, but keep the
  live document so Undo and Redo still target the displayed annotations. A
  manual save preserves the page index, zoom and `PDFView` instance.
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
- A note draft is part of that sequence, not an exception that is resolved
  eagerly. "Discard Draft" records a draft-only intent and leaves the composer
  session alive; `QuitCoordinator.commit` ends it only once the whole quit is
  allowed. A Cancel at the following document prompt — in this window or in any
  other — clears the intents without touching a draft. Draft and document
  approvals are separate and each is bound to both the draft and document
  revisions, so typing after answering asks again instead of inheriting the old
  answer.
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
  Undo and Redo count as edits too. Automatic saves keep the live
  `PDFDocument`, selected annotation and history, so ⌘Z remains available after
  each saved checkpoint. A manual save or Save As reload replaces the document
  and clears that history. Failed, conflicting and uncertain-replacement saves
  leave the history and selection in place.
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

### Notes (P2c)

A note is one standard PDF `/Text` annotation. The body is `/Contents` and
nothing else; the paper tint is written to `/C` and mirrored in an optional
`/YoPDFNotePaper` key, and the quoted excerpt and the page-note flag live in
`/YoPDFNoteExcerpt` and `/YoPDFNotePageLevel`. Losing any of the three custom
keys loses the tint and the quote, never the text, and there is no sidecar or
database — the saved PDF is the whole document.

- **The anchor is captured when the composer opens, not when Save is pressed.**
  A selection note records the page and the marker rectangle up front, so a
  click or a new selection while the popover is open cannot move it.
- **A cross-page selection is anchored on the first page of the selection, and
  only there.** The page comes from each line's own page, so a selection that
  passes through a page never annotates it. The marker sits just outside the
  top-right of the selected text, and flips to the left or clamps into the page
  when that would leave the sheet.
- **A page note never consults the text selection.** `pageNoteDraft(at:on:)`
  reads only the click point, so creating one while text is still selected
  cannot inherit that text or that page. The composer is reached from the
  toolbar (Add Note), `⇧⌘N`, the page context menu ("Add Note Here") or, with no
  selection, by placing the note with the crosshair that Add Note turns on.
- **The composer writes nothing until Save.** Body and paper are local SwiftUI
  state; Cancel closes the popover without a model call, so it cannot dirty the
  document or leave an Undo entry. A blank or whitespace-only body is refused by
  the model as well as disabled in the UI.
- **The input grows to four lines and then scrolls.** A vertical `TextField`
  with `lineLimit(1...4)` gives that behaviour; Return inserts a newline and
  `⌘Return` submits. The sticker face on the left opens the appearance popover
  (templates, six tints and the 20 motifs), and the `ellipsis` menu offers
  "Expand to Edit" and "Delete". Expand switches to the 540×560 sheet editor
  with a `TextEditor` for long notes, the same appearance controls and the same
  Save and Cancel, so there is only one commit path. An existing note reopens
  from its marker with its body and its style.
- **Twenty original sticker motifs and six paper tints.** Honey, Rose, Mint,
  Sky, Lavender and Sand remain the existing `NotePaperColor` values, used for
  `/C`, the composer paper and the marker's rounded-square fallback. Every motif
  has a stable raw ID and a 256×256 transparent PNG in
  `YoPDF/Resources/Assets.xcassets`; the inventory, provenance and SHA-256
  hashes are in `STICKER_ASSETS_MANIFEST.md`. Simple Paper (`plain`) has no
  illustration.
- **The sticker marker is a page overlay, not a written appearance.** PDFKit
  still draws its own icon for a `/Text` annotation, so the overlay redraws the
  page content with YoPDF's notes suppressed inside each marker rect and then
  paints the 32pt artwork with its shadow (or a tinted rounded square with the
  template's SF Symbol). The page shows one sticker while the file holds a
  standard note. The overlay is transparent to hit testing everywhere except a
  marker, where it shows a pointing-hand cursor and claims the click, so
  PDFKit's native note popup cannot open over the sticker. Markers are derived
  from the document (`noteMarkers`), never stored separately, so a marker cannot
  outlive its annotation.
- **Templates are a seed, not a reference.** The twelve built-in outlines carry
  ShuaMac's identities, symbols, tints, motifs and prompt text; personal
  templates live in `UserDefaults` under `YoPDFNoteTemplates.v1` and are edited
  in a 760×590 library sheet. Applying a template replaces the body only while
  the draft still holds the previous seed (or is empty), and it copies the
  appearance into the draft. The saved note stores its own style snapshot, so
  editing or deleting a template later cannot restyle an existing note. An
  unreadable template library is kept as stored and refuses writes instead of
  being silently replaced with an empty one.
- **Notes share the markup edit pipeline.** `addNote`, `updateNote` and
  `deleteNote` build one `MarkupEdit`, so a body change and a paper change in
  one editing gesture are a single Undo entry, and automatic saves preserve
  that history exactly as they do for highlights. Manual save reloads the
  document and rebuilds the markers from the file.
- **Permissions are re-read at execution time.** ReadOnly and Locked refuse
  body, colour and deletion; LockedContents refuses only `/Contents`, so the
  tint can still change and the note can still be deleted. The edit pipeline
  checks again for Undo and Redo, which is why a note that becomes protected
  keeps its history and stays editable once unlocked. A document that forbids
  commenting refuses new notes and every change.
- **PDFKit's popup companion is handled.** Adding a `/Text` annotation makes
  PDFKit attach a `/Popup` child; delete removes both and Undo restores both, so
  no empty popup icon is left behind. `/NM` is not written: PDFKit accepts one in
  memory and drops it on serialisation, so a note is identified by its object,
  not by a name the file would not keep.
- **Interoperability.** A note written here reads back through a separate
  `PDFDocument` with its body, tint and rectangle, and a `/Text` annotation
  created by another application (no YoPDF keys at all) can be read, edited and
  deleted here; its highlight and square neighbours survive the round trip.
  An untouched third-party note keeps PDFKit's native icon and native hit
  target. Restyling it through YoPDF adopts it explicitly (see P2d below).
  Apple Preview reads the body from `/Contents`. That was checked by inspecting
  the written annotation dictionary and by reopening the file in a separate
  PDFKit process, not by watching Preview's window.
- **ShuaMac thought groups.** ShuaMac writes each thought as a standard `/Text`
  annotation, stores the optional appearance JSON in `ShuaStickerStyle`, and
  includes the shared anchor UUID in `/NM` as
  `shua-thought:<anchor UUID>:<thought UUID>`. YoPDF recognizes those fields,
  paints one sticker and count badge per anchor, and masks the stack of native
  PDFKit icons. Clicking it opens the first note and a disclosure list keeps
  the other note bodies readable. A save temporarily writes the shared anchor
  ID under `/YoPDFShuaAnchorID`, because PDFKit may drop `/NM` while serializing;
  the live document is restored before the save returns.

### Sticker persistence (P2d)

- **`/YoPDFNoteStyle` is a versioned JSON string**, currently
  `{"v":2,"title":"","symbol":"note.text","motif":"bunny","palette":"honey"}`.
  A motif ID is the persistent identity; the collection is only a UI grouping.
  `title` and `symbol` are the template identity the expanded editor shows; a
  v1 value has neither and reads as an empty title with `note.text`. A style is
  a value on the annotation, so a future template cannot change a saved note.
- **`/YoPDFNoteAnchorX` and `/YoPDFNoteAnchorY` are numbers normalized to the
  page's CropBox** (0…1). The marker centre is
  `crop.minX + x * crop.width`, `crop.minY + y * crop.height`. For owned
  notes, rendering, hit testing and the popover all use
  `NoteService.markerCenter` and `NoteService.displayBounds`, so they cannot
  disagree. Third-party notes use their native annotation bounds instead.
- **`/YoPDFNoteIdentity` is the ownership marker**, currently
  `yopdf-note-1`. New notes write it. A note is recognised as YoPDF only when
  that key is present, or when the legacy PR #6 keys (`/YoPDFNotePaper`,
  `/YoPDFNotePageLevel`) are present. `/NM` is dropped by PDFKit, and
  `userName`, `/C` and the body are never used to infer ownership. Recognition
  is read-only: opening a PR #6 file does not add the identity key.
- **Untagged third-party `/Text` notes keep their native icon.** YoPDF notes and
  recognized ShuaMac thoughts enter `noteMarkers`; the latter are grouped by
  ShuaMac's anchor UUID and use its saved sticker style when available. An
  untagged third-party note uses its own annotation rectangle for hit testing,
  not an invisible sticker-sized card, and its popover points at the native icon.
- **Restyling a third-party note is the adoption point.** A body-only edit
  leaves it native. An explicit motif or palette change writes
  `/YoPDFNoteIdentity` and `/YoPDFNoteStyle` in the same `MarkupEdit`, so the
  note becomes YoPDF-styled. That edit carries an exact before/after snapshot
  (including the original `/C` and which keys were absent), so Undo removes the
  new keys and returns the note to its native icon and hit target.
- **`/Contents` remains the body.** `/YoPDFNotePaper` and `/C` stay in sync with
  the palette, so a PR #6 build or another reader still sees the right tint.
  Losing the style key costs the motif and tint, never the text.
- **Fallbacks are deliberate.** A missing or malformed style key becomes
  `plain` + the legacy paper. An unknown motif ID becomes `plain`; an unknown
  palette uses the legacy paper. None of these rewrites the file on open. A
  brand-new note does not use `plain`: it starts as `newNote` (Little Bunny on
  honey paper) and writes that motif explicitly, so no reader has to guess.
- **Existing notes are not migrated on open.** A PR #6 note keeps its `/Rect`
  centre and gains no anchor or identity key; only a note created by this build
  writes the 24×24 `/Rect` + normalized anchor. A third-party note is not
  touched at all. PDFKit may still rewrite an old `/Rect` on save, which is the
  pre-existing one-point drift, not a migration.
- **One Save is one Undo entry.** Body, motif, palette, title and symbol changes
  are packaged in one `MarkupEdit`; Undo restores the whole prior style.
  LockedContents permits a style change and refuses the body; ReadOnly and
  Locked refuse both.
- **Verification.** `macos/scripts/verify-sticker-assets.sh` checks the manifest
  hashes, the 20 imagesets, the built `Assets.car` renditions (20, 256×256,
  alpha) and loads every asset through AppKit from the actual `.app` bundle.
  The unit tests pin the style wire format (v1 read, v2 write, body-only edits
  adding no keys), the anchor math, the 32pt marker face and 3pt hit inset, the
  template seed rules, and the refusal to overwrite an unreadable template
  library. Window-level rendering of the marker is still a manual check (see
  below).

Known P2a/P2b limitations:

- No StrikeOut, free-text or ink annotation editing, and no annotation search.
  The sidebar indexes standard PDF annotations for navigation. YoPDF-created
  notes still store one body per annotation.
  Imported ShuaMac groups show their count and all bodies, but YoPDF currently
  edits only the first note in the group; adding, editing and deleting other
  group members remains future work. Templates only seed drafts and are not
  stored in the document.
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

Known P2c/P2d limitations:

- A note body is plain text. `/Contents` holds no formatting, and the composer
  does not offer any.
- The paper tint is written to `/C`, so another viewer that draws the standard
  note icon draws it in that colour too. "Paper colour only affects YoPDF" is
  true of the marker and the composer card; it cannot be true of a viewer that
  renders `/C` itself, and suppressing `/C` would make the note look unrelated
  in other applications.
- The sticker marker is a fixed-size overlay centred on the persisted anchor.
  It follows the page transform like the P2b selection outline, but this
  environment cannot capture a window, so card alignment after zoom/scroll,
  rotated pages, edge clamping and coverage of PDFKit's native icon are still
  manual checks. Unit tests verify the anchor math, the saved keys and asset
  loading, not pixels on screen.
- Popover placement is computed from the PDFView's bounds (converted from the
  unflipped AppKit origin). The composer's layout was rendered offscreen, but
  the arrow's position on a real window — including near a screen edge — has not
  been observed.
- Placement mode consumes the click that places the note, so a drag cannot
  position it; one click, one note. There is no drag-to-move for an existing
  marker yet.
- A note is deleted without a confirmation dialog. It is a single Undo away and
  the composer says so, but a user who does not know ⌘Z may be surprised.
- The template library is a flat list. There are no template folders, no
  import/export, and no per-document templates; personal templates are
  preferences on this Mac, so they do not travel with a PDF. Creating and
  editing grouped notes, drag-to-move and a document-wide note list are later
  stages.
- A future `/YoPDFNoteStyle` version is read leniently, but unknown fields in
  that value are not preserved when the style is rewritten. `v` is recorded so a
  later migration can change that without guessing.
- Artwork parity is a visual acceptance item. The exact 256 px PNGs are the
  ShuaMac runtime assets, but the card scale, border and decoration were written
  natively here and must be compared side by side in a GUI session.
- `Assets.car` re-encodes PNGs. Manifest hashes are of the source runtime PNGs;
  the verification script checks those hashes plus the compiled rendition names,
  dimensions and alpha, not the bytes inside `Assets.car`.

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
    contents and flags set by another app survive, and the edit is saved through
    the normal `DocumentSession` path. After the automatic save, Undo remains
    available and reverses the last edit; the reverted state is saved as the
    next automatic checkpoint. A manual save reloads the document and clears
    Undo history.
11. Simulate a save conflict (change the file from another app) after recolouring:
    the save is refused, the annotation and the Undo history stay in the window,
    and Save As remains available.
12. Select a sentence and press Add Note (or ⇧⌘N): the popover points at the
    marker position, the quote is the selected text, Return inserts a newline and
    ⌘Return saves. Esc or Cancel closes it with no "Edited" indicator and no Undo
    entry.
13. With no selection, press Add Note: the cursor becomes a crosshair and one
    click on a page places the note there. Esc cancels the placement. Do this
    while text is still selected: the new note must be a page note, on the page
    that was clicked.
14. Select text across a page break, add a note, and check the marker: it must be
    on the first page of the selection, and the second page must have no marker.
15. Click a marker: the note reopens with its body and tint. Change the body and
    the paper, Save, then ⌘Z twice: the tint and then the body revert.
16. Zoom to 200% and 50%, and scroll: markers stay on their notes and stay
    clickable; the popover still points at the marker it belongs to.
17. Type a note long enough to pass four lines: the field stops growing and
    scrolls internally. Expand it, keep typing, collapse, and save: the body is
    the same either way.
18. Save a note, quit, reopen the file in YoPDF and in Apple Preview: the marker
    is where it was, and Preview's note list shows the body text.
19. Open a PDF whose notes come from another application: their markers appear,
    their body can be edited, and deleting one does not disturb a highlight next
    to it.
20. Right-click a marker: Edit Note and Delete Note appear above PDFKit's items;
    right-click empty page space: Add Note Here appears. Neither replaces the
    PDFKit zoom/display items.
21. With both an unsaved note draft and unsaved document edits, ⌘Q → Discard
    Draft → Cancel: the window stays open, the note text is still in the
    composer, and the document is still marked edited.
22. Window A has an unsaved note draft; window B has unsaved document edits.
    ⌘Q → A "Discard Draft" → B "Cancel": A's note text must still be there and a
    second ⌘Q must ask A about the draft again.
23. Repeat the two-window case with both windows approving exit: the app quits.
    The deferred discard has only been exercised through logic tests here, not
    through a real window or a real termination.
24. Create a note, open the Sticker menu and choose all 20 illustrated motifs
    plus Simple Paper. The preview and the page marker follow the selection;
    Save, quit, reopen: every motif and tint is still there, and reopening the
    note shows the same selection in the menu.
25. Compare the same page content side by side with ShuaMac: artwork, card
    colour, border/dashed treatment, artwork scale and marker size. Record the
    differences; this PR does not claim pixel parity.
26. With a sticker marker over the native note icon, zoom between Fit and 200%
    and scroll: exactly one sticker is visible, it stays anchored, and text
    selection/copy still works through and around it.
27. Rotate a page and use a PDF with a non-zero CropBox origin: markers stay on
    the same page point after save/reopen, and a click still opens the right
    note.
28. Change only the motif or only the palette, confirm "Edited" appears, dismiss
    the popover, then reopen "Note Draft": the style is still selected. Do this
    in two windows and cancel a quit: both style drafts survive.
29. With a LockedContents note, change the motif: Save succeeds and the body is
    unchanged; try to change the body: it is refused. With ReadOnly/Locked, the
    motif and palette controls are disabled.
30. Open a PDF with a third-party `/Text` note that has no YoPDF keys: it must
    show PDFKit's native icon, not a sticker card. Clicking the icon opens the
    composer; clicking just outside the native rectangle must not hit it.
31. In that third-party note, change only the body and Save: the native icon
    must remain. Reopen it, change the motif or palette and Save: it becomes a
    sticker note; ⌘Z must return it to the native icon and original colour.
32. Open a ShuaMac PDF with several `shua-thought:<anchor>:<thought>` notes:
    each anchor shows one sticker with the correct count, the first sticker style
    is used, the hidden native icon stack does not show through, and the disclosure
    lists the remaining note bodies. Save, close and reopen; the group count must
    survive PDFKit serialization via `/YoPDFShuaAnchorID`.
33. Open a PDF, navigate to a later page and choose a manual zoom. Quit and
    relaunch: the file appears at the top of File → Open Recent, and reopening it
    restores the page and zoom. Repeat with Fit mode; the new window recalculates
    the fit for its own size.
34. Open a recent file after moving it: the bookmark follows it and the restored
    page stays associated with that document. If the bookmark cannot resolve,
    choose Relink… and select the moved PDF. The original recent entry keeps its
    page and zoom, and no duplicate appears. Cancel the picker and try a corrupt
    PDF; neither operation changes the original entry.
35. With unsaved document edits or a note draft, choose a recent file. Save,
    Don't Save and Cancel must follow the same prompts and preserve the same
    edits and draft state as Open PDF….

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
added yellow highlights with a manual save; committed annotation changes now
auto-save. P2b makes Highlight and Underline
editable: selection, six presets plus custom colours, recolour, delete, convert
and Undo/Redo. P2c adds standard `/Text` notes with a compact composer, six paper
tints, page markers, editing, deletion and Undo/Redo. P2d adds 20 original
sticker motifs, a persistent versioned style (v2 with template title and symbol),
a CropBox-relative marker anchor, twelve built-in templates with a personal
template library, and ShuaMac's compact composer. P2e adds Outline, Thumbnails
and Annotations views to a collapsible sidebar attached to the open PDF window.
Annotation changes auto-save; there is no document library, StrikeOut support,
note threads or agent integration. Recent files and reading-position restoration
have since been added without introducing a managed library.

Known P1 boundaries:

- A recent entry is a file-access bookmark and a reading position; it is not a
  saved multi-window session. The user chooses which recent PDF to reopen.
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
