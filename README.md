# YoPDF

A free, open-source, local-first PDF reader and annotator for macOS and Windows,
built natively for each platform. **Your PDF. Your way.**

YoPDF is in early development. The repository currently contains the macOS
reader: opening a local PDF, continuous scrolling, page navigation, zoom, and
standard PDF Highlight/Underline annotations with manual save. Search and
AI-assisted reading are not implemented yet.

## Status

| Area | State |
| --- | --- |
| macOS app (SwiftUI + AppKit + PDFKit) | Reader with editable Highlight/Underline annotations |
| Unit tests | 158 logic tests |
| Annotations | Standard `/Highlight` and `/Underline`: selection, colours, recolour, delete, convert, Undo/Redo |
| Windows (WinUI 3 + PDFium) | Feasibility work, not in this repository yet |
| AI / agent integration | Not started |

Nothing here is a release. There is no signed or notarized build.

## Build and run (macOS)

Requirements: macOS 14 or later, Xcode 16 / Swift 6, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
cd macos
./scripts/build.sh          # Debug build
./scripts/test.sh           # unit tests
CONFIGURATION=Release ./scripts/build.sh
open build/DerivedData/Build/Products/Debug/YoPDF.app
```

`scripts/build.sh` and `scripts/test.sh` regenerate the Xcode project
automatically when `project.yml` changes, so a fresh clone needs no extra step
beyond installing XcodeGen. Build products stay in `macos/build/` (git-ignored).

## Design constraints

- **Local-first.** Reading and annotating must work without a network, an
  account, or a model.
- **Native.** SwiftUI + AppKit + PDFKit on macOS; WinUI 3 + PDFium is the
  candidate for Windows, still to be validated.
- **Standard formats.** Annotations are written as standard PDF annotations so
  other readers can open the result. Application-specific data is kept separate
  and is never required to render a document.
- **Untrusted input.** PDFs are data, never instructions.

## Repository layout

```
macos/
├── project.yml        # XcodeGen spec (the .xcodeproj is generated)
├── YoPDFCore/         # reader logic, no UI, unit-tested
├── YoPDF/             # SwiftUI app
├── YoPDFTests/        # logic tests
└── scripts/           # generate / build / test
```

## License

Apache-2.0. See [LICENSE](LICENSE).

Third-party dependencies, fonts, and sample documents require their own
provenance review before redistribution. The YoPDF name and logo are not
covered by the source license.
