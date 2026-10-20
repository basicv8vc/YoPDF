# YoPDF for macOS

Native PDF reader built with **SwiftUI + AppKit + PDFKit**. It opens local PDFs
directly from disk and renders them; there is no managed library, no network
code, no account system, and no agent integration.

P1 adds a file-first `DocumentStore` in `YoPDFCore`: file identity and version
tracking, external-change detection, and safe in-place saving. There is no Save
command in the UI yet — the save path is exercised through the Core API and its
tests, and no document is presented as "edited" before annotations exist.

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
./scripts/test.sh                     # unit tests (72)
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
│   ├── PDFDocumentModel.swift
│   ├── ReaderViewSync.swift    # pure page/zoom decisions used by the bridge
│   └── SecurityScopeAccess.swift
├── YoPDF/
│   ├── App/YoPDFApp.swift      # @main, one model per window
│   ├── App/PDFReaderCommands.swift
│   ├── App/ReaderFocusedValues.swift
│   └── Reader/
│       ├── PDFViewerRepresentable.swift # PDFView ↔ SwiftUI bridge
│       └── PDFReaderView.swift          # toolbar, empty state, drag & drop
├── YoPDFTests/
│   ├── PDFFixtureFactory.swift # generates real PDFs at runtime
│   ├── SecurityScopeSpy.swift
│   ├── PDFDocumentModelTests.swift
│   ├── DocumentSecurityScopeTests.swift
│   ├── DocumentStoreTestSupport.swift   # temp dirs, payloads, fault injection
│   ├── DocumentStoreTests.swift         # sessions, versions, external changes
│   ├── DocumentStoreSaveTests.swift     # save / Save As contract
│   ├── DocumentStoreFailureTests.swift  # injected staging/commit failures
│   ├── DocumentStoreScaleTests.swift    # 200 MB streaming and save
│   ├── DocumentStoreModelIntegrationTests.swift
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
conflict instead of being overwritten, and a failed save leaves the original
bytes untouched.

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
accounts, sync and PDF editing. P1 adds only file access and safe persistence:
no annotations, no undo, no autosave, no document library, no Save UI.

Known P1 boundaries:

- Security-scoped bookmarks are not created. Nothing needs to survive a window
  restoration yet, so a session holds a runtime scope only.
- Symlinks, hard links and undownloaded cloud placeholders are refused by
  `save` rather than written through; `saveAs` is the escape hatch.
- Crash durability is bounded by what is testable here: failure paths are
  verified to leave the original bytes intact, but "power loss at every instant"
  is not claimed.
- The 200 MB test skips itself when the volume has less than 800 MB free, since
  it needs room for the file plus its staging copy.
