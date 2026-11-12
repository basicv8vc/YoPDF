# YoPDF Multi-Pane Layout Engine Spike Report (DEC-08)

**Task**: P0-B-A Workspace Layout Core & Layout Engine Spike
**Author**: Senior macOS Architect / Swift Engineer
**Date**: November 2026
**Status**: Completed Spike Evaluation (DEC-08 Status: PROVISIONAL)
**Reference Specification**: `Docs/architecture/HETEROGENEOUS-MULTI-PANEL-ARCHITECTURE.md` (DEC-08)

---

## 1. Test Environment

| Parameter | Recorded Value |
| :--- | :--- |
| **Operating System** | macOS 26.7.2 (Darwin Kernel Version 25G332) |
| **Xcode Version** | Xcode 27.2 (Build version 27B52) |
| **Swift Toolchain** | Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1) |
| **Host Architecture** | Apple Silicon (`arm64`) |
| **Window Geometry Tested** | 641 × 481 pt (minimum 2-pane threshold: $320 \times 2 + 1 = 641\text{ pt}$ width, $240 \times 2 + 1 = 481\text{ pt}$ height) to 2560 × 1440 pt |
| **Baseline `LayoutPolicy`** | `minimumLeafWidth: 320 pt`, `minimumLeafHeight: 240 pt`, `dividerThickness: 1 pt`, `maxPanes: 4` |

---

## 2. Executive Summary & DEC-08 Recommendation

### Architectural Decision DEC-08 Status: **PROVISIONAL — Pure SwiftUI Recursive Layout (Preferred Candidate)**

We evaluated two architectural candidates using identical geometry definitions:
1. **Candidate A**: Pure SwiftUI Recursive Layout Engine driven directly by `WorkspaceLayoutTree`.
2. **Candidate B**: AppKit `NSSplitViewController` wrapped by SwiftUI via `NSViewControllerRepresentable`.

### Core Recommendation:
**Adopt Candidate A (Pure SwiftUI Recursive Layout) as the preferred implementation candidate**, with final validation reserved for Stage P0-B multi-pane GUI integration.

### Architectural Rationale & Hypotheses:
- **Zero Synchronization Impedance (Architectural Invariant)**: `WorkspaceLayoutTree` is the single source of truth. Tree mutations flow unidirectionally into view evaluation (`LayoutTree -> View`). In contrast, Candidate B requires complex two-way synchronization between declarative state and imperative `NSSplitViewDelegate` events.
- **Drop Zone Overlay Feasibility**: SwiftUI declarative `.overlay` layer with `.allowsHitTesting(false)` enables visual preview highlights without interfering with pointer events. Candidate B requires managing overlay `NSView` hierarchies above platform scroll views.
- **Mathematical Layout Performance**: Pure functional geometry calculations require **4.19 µs per frame** at the model layer on Apple Silicon.

---

## 3. Structured Trade-Off Comparison (7 Criteria)

> [!NOTE]
> This comparison distinguishes measured model calculations from architectural analyses. A completed head-to-head GUI benchmark was not run, as Candidate B's synchronization was intentionally left unimplemented per CTO scope boundaries.

| # | Evaluation Factor | Pure SwiftUI Recursive Tree | AppKit `NSSplitViewController` Representable | Status / Verdict |
| :--- | :--- | :--- | :--- | :--- |
| **1** | **Divider Dragging Responsiveness** | Custom divider view with `DragGesture` computes displacement relative to a stable drag-start dimension. Clamped live via `LayoutNode.clampedRatio`. | Uses native AppKit window server divider tracking loop. | **Measured**: Model clamping executes in 4.19 µs/frame.<br>**Drag Arithmetic**: Verified in unit tests.<br>**Interactive GUI DragGesture**: UNVERIFIED (provisional). |
| **2** | **3-Level Nested Split Stability** | Pure functional mapping (`LayoutNode -> View`) with direct frame allocation. No constraint solver involved. | Relies on nested `NSSplitViewController` hierarchies. Each level introduces an internal Auto Layout constraint system. | **Architectural Analysis**: SwiftUI avoids nested constraint solver state. |
| **3** | **Rapid Window Resizing** | Container dimensions passed down through `GeometryReader`. Functional geometry calculation scales deterministically. | Uses `splitView(_:resizeSubviewsWithOldSize:)`. Maintaining proportional subview ratios across nested splits requires custom delegate arithmetic. | **Architectural Analysis**: Functional calculation is mathematically deterministic. |
| **4** | **Minimum Dimension Enforcement** | Enforced mathematically in `LayoutNode.clampedRatio` ($r_{\min} \le r \le r_{\max}$). Frame width/height cannot drop below policy minimums while space permits. | Enforced via `NSSplitViewItem.minimumThickness`. In nested splits, parent split items do not automatically aggregate child minimums without custom recursive propagation. | **Empirically Verified**: 0 violations across 3,000 stress iterations in model benchmarks (Horizontal, Vertical, Asymmetric). |
| **5** | **Drop Zone Overlay Feasibility** | Visual preview overlay rendered with `.allowsHitTesting(false)`. Interactive drop targets handle events explicitly without disturbing underlying content. | Requires injecting floating or subview `NSView` layers over AppKit subviews, introducing CoreAnimation layer-ordering complexity. | **Prototype Feasibility Confirmed**: SwiftUI approach is substantially simpler. |
| **6** | **VoiceOver Accessibility** | Programmatic SwiftUI accessibility tree (`.accessibilityElement(children: .contain)`). Dividers exposed with `.isButton` accessibility traits. | Mature native AppKit accessibility hierarchy (`NSAccessibilitySplitGroupRole`, `NSAccessibilitySplitterRole`). | **Programmatic Elements Confirmed**.<br>**Interactive VoiceOver Session**: UNVERIFIED. |
| **7** | **Tree Synchronization Complexity** | **Zero impedance**. Unidirectional data flow. Visual pane models preserve identity via `id(paneID)`. | **High Impedance**. Bridging declarative tree into stateful `NSSplitViewController` requires diffing child controllers, risking teardown of active `PDFView`s. | **Architectural Analysis**: Decisive advantage for Pure SwiftUI. |

---

## 4. UI Prototype Compilation Verification Status

Both spike implementation files have been verified for compilation against `YoPDFCore.framework`:

1. **`spikes/LayoutEngineSpike/PureSwiftUILayout.swift`**:
   - **Compilation Command**: `swiftc -typecheck spikes/LayoutEngineSpike/PureSwiftUILayout.swift -F macos/build/DerivedData/Build/Products/Debug`
   - **Status**: **COMPILED CLEANLY** (0 errors, 0 warnings under Swift 6).
   - **Verification Scope**: Verifies syntax, SwiftUI view hierarchy composition, `LayoutPolicy` parameterization, and drag coordinate arithmetic.
2. **`spikes/LayoutEngineSpike/AppKitSplitViewControllerLayout.swift`**:
   - **Compilation Command**: `swiftc -typecheck spikes/LayoutEngineSpike/AppKitSplitViewControllerLayout.swift -F macos/build/DerivedData/Build/Products/Debug`
   - **Status**: **COMPILED CLEANLY** (0 errors, 0 warnings under Swift 6).
   - **Verification Scope**: Verifies syntax, AppKit controller instantiation, `NSSplitViewDelegate` conformance, and `NSViewControllerRepresentable` coordinator protocol contracts.

> [!CAUTION]
> **Compilation status verifies type safety, protocol contracts, and API compatibility only.** It does NOT constitute live GUI runtime validation, on-screen event dispatch, or visual rendering in a running macOS window, all of which remain explicitly **UNVERIFIED** until production integration in Stage P0-B.

---

## 5. Empirical Benchmark Measurements (Model Layer)

Executed on Apple Silicon (macOS 26.7.2, arm64) using `spikes/LayoutEngineSpike/SpikeBenchmark.swift`.

> [!IMPORTANT]
> These benchmarks measure **Layout Core mathematical geometry computation throughput**, NOT full SwiftUI or AppKit GUI view rendering passes. They do not constitute a completed GUI benchmark between the two frameworks.

### Benchmark 1: Recursive Geometry Computation Throughput
- **Geometry Tree**: 3-level nested binary split tree (4 panes: `P1 | (P2 / (P4 | P3))`).
- **Warm-up**: 1,000 unmeasured warmup evaluations before timing.
- **Iterations**: 10,000 deterministic indexed container size resizes (varying from 800×600 to 2000×1400 pt, zero random number generation in timed loop).
- **Result Consumption**: Computed frames accumulated into an observable checksum printed outside the loop.
- **Total Execution Time**: **0.0419 seconds**.
- **Average Frame Computation**: **4.19 microseconds (µs)**.
- **Throughput**: 238,746 evaluations/sec.
- **Accumulated Geometry Checksum**: `78986272.82` (verifies complete observable consumption).
- **Analysis**: The mathematical geometry model consumes ~4.19 µs per evaluation on Apple Silicon. This confirms that layout calculations add negligible overhead to the run loop. Actual UI rendering performance (including Quartz Compositor and `PDFView` page tiling) will be measured during Stage P0-B GUI integration.

### Benchmark 2: Dynamic Ratio Clamping Invariant Verification
- **Test Suites (3 deterministic suites, 3,000 total iterations)**:
  1. **Suite 2A (Horizontal Split)**: 1,000 iterations, widths 641...2000 pt, requested ratios `[-1.0 ... +2.0]`, plus `.nan`, `+.infinity`, `-.infinity`. Expected pane count: 2.
  2. **Suite 2B (Vertical Split)**: 1,000 iterations, heights 481...1800 pt, requested ratios `[-1.0 ... +2.0]`, plus `.nan`, `+.infinity`, `-.infinity`. Expected pane count: 2.
  3. **Suite 2C (Asymmetric Nested Split `P1 | (P2 | P3)`)**: 1,000 iterations, widths 962...2500 pt, heights 500...1000 pt, root ratios `[-1.0 ... +2.0]` (including non-finite), nested ratios `[-0.5 ... +1.5]`. Expected pane count: 3.
- **Fail-Safe Mechanism**: The benchmark actively asserts for every frame:
  - `isFinite(origin.x)`, `isFinite(origin.y)`, `isFinite(size.width)`, `isFinite(size.height)`.
  - `width >= policy.minimumLeafWidth - 0.01` and `height >= policy.minimumLeafHeight - 0.01`.
  - `frames.count == expectedPaneCount` (2A = 2, 2B = 2, 2C = 3).
  - Any violation increments `violations` and terminates with `exit(1)`.
- **Observed Violations**: **0 violations across all 3,000 iterations**.
- **Status**: **PASSED (100% Invariant Satisfaction, process exited with code 0)**.

### Benchmark 3: Tree Serialization & Decoding Overhead
- **Payload Size**: 460 bytes (JSON).
- **Warm-up**: 100 unmeasured warmup decodes.
- **Iterations**: 1,000 decodes with decoded results observably consumed via `paneCount` and `leafIDs.count`.
- **Total Execution Time**: **0.0216 seconds**.
- **Average Decode Latency**: **21.61 microseconds (µs)** across 1,000 iterations.
- **Accumulated Decode Checksum**: `8000` (verifies complete observable consumption).
- **Status**: Confirms that deserializing window layout state on launch is fast and lightweight.

---

## 6. Verification Boundaries & Known Limitations

In compliance with repository policy:
- **VoiceOver Interactive Validation**: Programmatic accessibility structures are defined, but interactive rotor navigation and spoken announcements with VoiceOver enabled in a running GUI process are marked **UNVERIFIED** (cannot be tested in a headless CI/sandbox toolchain).
- **120Hz Display Performance**: While mathematical calculation takes 4.19 µs/frame, on-screen 120Hz VSync delivery depends on the production view hierarchy and `PDFView` rendering pipeline. Real-world display smoothness remains to be validated during GUI integration.
- **Divider Dragging in GUI**: Drag displacement arithmetic is mathematically verified against drift and reversals in unit tests; real-time interaction with SwiftUI `DragGesture` events in an active macOS window remains **UNVERIFIED** pending full integration.
- **Drop Zone Interaction**: The prototype demonstrates hover visual feedback only. Real drop target registration, drag session coordination, and non-interference with PDFKit text selection/annotation gestures belong to Stage P0-B-D and remain **UNVERIFIED** until full integration.
- **DEC-08 Status**: Marked **PROVISIONAL**. Pure SwiftUI is the preferred candidate, with final confirmation deferred to production reader integration.

---

## 7. Implementation Action Plan for Stage P0-B

1. **Step 1 (Approved)**: Adopt `WorkspaceLayoutTree` as the core layout engine model in `YoPDFCore` (completed in PR #48).
2. **Step 2 (P0-B-B)**: Wire `PureSwiftUIRootLayoutView` from `spikes/LayoutEngineSpike/PureSwiftUILayout.swift` into `WorkspaceTab` to render multi-pane layouts.
3. **Step 3 (P0-B-D)**: Implement transactional drag-and-drop delivery and drop zone hit-testing for pane creation and session movement.
