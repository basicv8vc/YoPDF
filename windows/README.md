# YoPDF for Windows (GPUI Kit + PdfCraft)

Native Windows PDF Reader & Annotator built in Rust using
**GPUI Kit** (`0.9.1`, DirectX 11 + DirectWrite on Windows) and the
**PdfCraft** (`v0.20.0`) PDF engine via [`pdfcore`](pdfcore/).

> **Validation Status:** Unit tests (`pdfcore` and `yopdf-gpui`), macOS host
> compilation, and `cargo-xwin` `x86_64-pc-windows-msvc` cross-compilation checks
> pass. Native runtime execution, DirectX 11 GPU rendering, and native Windows
> file/save dialog smoke verification on Windows 10 22H2 and Windows 11 x64
> (**Slice A.5**) remain pending. Do not treat `cargo-xwin check` as Windows
> runtime verification.

## Windows Support Policy

- **Minimum supported OS:** Windows 10 22H2 (Build 19045), x64 / AMD64
- **Recommended OS:** Windows 11 x64 (Build 22000+)
- Same product UI and feature behavior across Windows 10 and Windows 11.

## Directory Layout

```text
windows/
├── Cargo.toml             # Workspace (pdfcore + gpui-app) and PdfCraft [patch.crates-io]
├── Cargo.lock             # Locked Rust dependencies
├── pdfcore/               # UI-independent PdfCraft engine facade & safety guards
├── gpui-app/              # GPUI Kit desktop application (yopdf-gpui)
├── fixtures/              # Synthetic deterministic test PDFs + generator
├── scripts/fetch-deps.sh  # Clones pinned PdfCraft v0.20.0 into third_party/pdfcraft
└── THIRD_PARTY_NOTICES.md
```

## Implemented Functionality

- **Reader core (`pdfcore`)**: Document lifecycle, concurrent page rasterization
  with cancellation, line-block text extraction, full-text search, SHA-256 +
  mtime external-change detection (`DiskVerdict`), incremental PDF saves,
  `Save As` destination preflight & path re-pointing, Highlight / Underline /
  StrikeOut / Sticky Note annotations, color updates, and Undo/Redo.
- **Native GPUI app (`gpui-app`)**:
  - Multi-tab document workspace, continuous scrolling, zoom/fit modes, page
    navigation, full-text search bar, outline/thumbnails/annotations sidebar.
  - Drag text selection, Highlight / Underline / StrikeOut / Sticky Note tools,
    6 preset sRGB colors matching macOS parity, click-to-select & recolor/edit/delete.
  - Per-tab `SaveController` with edit gating during saves, `750ms` debounced
    autosave with `Unverified` bounded retry, and generation-numbered config JSON.
  - Unbounded `SaveRegistry::drain_all()` barriers on window close and app quit
    (synchronously draining in `on_app_quit` before GPUI's `200ms` shutdown timeout),
    plus background non-blocking tab-close drain.
  - App-level `Save As` overwrite confirmation dialog before setting
    `overwrite_existing_destination: true` (since `gpui-pre-windows` `IFileSaveDialog`
    does not explicitly guarantee `FOS_OVERWRITEPROMPT`).

## Prerequisites & Commands

From `windows/`:

1. **Fetch pinned PdfCraft (`v0.20.0`)** into git-ignored `third_party/pdfcraft/`:

   ```bash
   ./scripts/fetch-deps.sh
   ```

2. **Build & run unit tests** (requires Rust toolchain `1.96+`):

   ```bash
   cargo test -p pdfcore
   cargo test -p yopdf-gpui
   cargo build -p yopdf-gpui
   ```

3. **Windows x64 cross-compilation check (from macOS/Linux)** with `cargo-xwin`:

   ```bash
   cargo xwin check -p pdfcore -p yopdf-gpui --target x86_64-pc-windows-msvc
   ```

4. **Windows native build (on Windows 10/11 x64)**:

   ```powershell
   cargo test -p pdfcore
   cargo test -p yopdf-gpui
   cargo build --release -p yopdf-gpui
   ```
