# YoPDF for macOS

Native PDF reader built with **SwiftUI + AppKit + PDFKit**. This is the P0
skeleton: it opens local PDFs, renders them, and navigates/zooms. There is no
network code, no account system, and no agent integration.

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
./scripts/test.sh                     # unit tests (31)
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
│   └── ReaderViewSyncTests.swift
└── scripts/{generate,build,test}.sh
```

Each `WindowGroup` window owns its own `PDFDocumentModel`. Menu commands read the
focused window's model through `FocusedValues`, so zoom/page actions and the open
panel apply to the active window only.

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

P0 intentionally excludes: annotations, search, recent documents, tabs, agent
integration, accounts, sync, PDF editing.
