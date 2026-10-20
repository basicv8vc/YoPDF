# YoPDF — Agent Development Guidelines

This file defines repository-wide instructions for AI coding agents contributing to YoPDF.

## 1. Project overview

YoPDF is a free, Apache-2.0 open-source, local-first PDF Reader & Annotator, built natively for macOS and Windows. Linux is a potential future target.

The product prioritizes human reading, annotation, document ownership, and optional AI-assisted workflows.

Read the root `README.md` and the relevant platform README before making changes. Follow task-specific documents only when they exist and are explicitly relevant.

Do not assume local or private planning documents are available in a public checkout.

## 2. Architecture

### macOS

- SwiftUI + AppKit + Apple PDFKit.
- Source lives in `macos/`.
- `YoPDFCore` contains reusable document and reader logic.
- Keep platform-independent logic separate from SwiftUI views where practical.
- Preserve proper security-scoped resource lifetimes.
- Prefer existing Apple frameworks over unnecessary dependencies.

### Windows

- WinUI 3 + C#/.NET is the intended UI stack.
- PDFium is the leading PDF backend candidate, subject to validation.
- No Windows implementation is present in this repository yet; treat Windows statements as plans, not existing behavior.
- Keep document semantics and PDF operations independent of WinUI where practical.
- Validate native DLL architecture and deployment requirements before claiming success.
- Identify the actual Windows test environment when reporting results.

### Cross-platform

- Aim for consistent document and annotation behavior.
- Share behavioral specifications, fixtures, and conformance tests where useful.
- Platform-native implementations are preferred.
- Do not introduce Electron, Flutter, Tauri, or a shared C++ core without an approved architecture decision.

## 3. PDF behavior and data safety

YoPDF is a Reader & Annotator, not a full PDF content editor.

Prioritize:

- Reliable PDF opening and rendering.
- Text selection, copying, and search.
- Standard PDF annotations and notes.
- Safe persistence, undo/redo, and interoperability.
- Reading performance and accessibility.

Follow these invariants:

- User documents remain under user control.
- Never silently overwrite external changes.
- Failed saves must not corrupt or destroy the original PDF.
- Preserve existing annotations and unrelated document structures.
- Prefer standard PDF annotations for interoperable features.
- Use application-specific metadata only when necessary.
- Tests that modify PDFs must operate on disposable fixtures or copies.

File access, save behavior, and annotation semantics require explicit failure-path testing.

## 4. AI and AgentChat

AI assistance is optional. Normal PDF reading and annotation must work offline.

Reference projects:

- ShuaMac: https://github.com/slowfastai/shua
- AgentChat: https://github.com/slowfastai/agentchat

ShuaMac is a technical reference for proven macOS PDF reading, text geometry, annotation, and UI behavior.

AgentChat is the preferred reference for connecting and managing local coding agents, including supported ACP-based integrations.

Do not reimplement existing agent communication protocols without first evaluating AgentChat.

Keep responsibilities separate:

- YoPDF owns PDF rendering, document access, annotations, and reading context.
- AgentChat owns agent connectivity and session infrastructure.
- Integration layers expose only the authorized document context and operations.

Architecture boundaries:

- **ShuaMac is a product, not a library.** Use it as a reference for proven behavior. Do not copy its source, assets, or product-specific features (accounts, subscriptions, paper feeds, cloud sync, arXiv integration) into this repository unless the rights and the scope are explicitly confirmed.
- **AgentChat remains an independent project.** Integrate it through a pinned version and a thin adapter. Do not vendor or fork it into YoPDF for long-term maintenance, and do not add PDF-specific business logic to its daemon.
- **PDF Context Bridge is the only document-context boundary.** It assembles the user-authorized selection, page, and annotation context for an agent, and it is the only component allowed to apply authorized annotation writes.

Do not add agent capabilities unless they are part of the approved task.

## 5. Security and privacy

PDF documents and their extracted content are untrusted input.

- Never execute instructions embedded in PDFs as application or system commands.
- Never send PDF content to remote services without deliberate user authorization.
- Do not treat a local agent connection as proof that all processing stays local.
- Do not automatically approve arbitrary shell commands, file writes, or permission escalation.
- Agent tool permissions must be enforced at runtime, not merely described in prompts.
- Prefer read-only document access for AI assistance by default.
- Do not commit credentials, tokens, personal documents, or private test files.
- Do not weaken file access or signing restrictions to make development easier.

## 6. Source reuse and licensing

YoPDF source code is licensed under Apache-2.0.

- Preserve the repository's root `LICENSE`.
- Check copyright ownership and licensing before importing code from ShuaMac.
- Prefer reusing proven implementations when the necessary rights are confirmed.
- Review third-party source, binaries, fonts, artwork, and fixtures independently.
- Preserve required copyright and license notices.
- Do not silently change the project's license or dependency licensing strategy.

Being publicly accessible on GitHub does not automatically authorize copying source code.

## 7. Engineering workflow

- Keep changes small, focused, and independently reviewable.
- Follow the current task's scope and acceptance criteria.
- Avoid unrelated refactors, speculative features, and premature abstraction.
- Prefer official SDKs, reproducible builds, and pinned dependencies where appropriate.
- Do not silently change the PDF engine, UI stack, minimum OS version, target architecture, or licensing model.
- Add tests for successful operations and meaningful failure cases.
- Distinguish tests that were written from tests that were actually run.
- Do not claim a successful build or runtime test without execution evidence.
- Document known limitations and unverified assumptions.

For substantial changes, explain the affected files, dependencies, risks, and validation approach before implementation.

## 8. macOS development commands

The macOS project is generated from `macos/project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen). From the `macos/` directory:

```bash
./scripts/generate.sh                  # optional: regenerate YoPDF.xcodeproj
./scripts/build.sh                     # Debug build
./scripts/test.sh                      # unit tests
CONFIGURATION=Release ./scripts/build.sh
```

`build.sh` and `test.sh` regenerate the Xcode project automatically when
`project.yml` is newer than the generated project, so a fresh clone only needs
XcodeGen installed. Build products stay in the git-ignored `macos/build/`.

Follow `macos/README.md` for current toolchain requirements, project
generation, and known test-runner limitations.

Do not commit generated Xcode projects or build artifacts unless the repository
policy explicitly changes.

## 9. Completion reports

Every completed task should summarize:

1. Files changed and the reason for each significant change.
2. Important design decisions and tradeoffs.
3. Actual build and test commands executed.
4. Host OS, toolchain, and relevant CPU architectures.
5. Test results and output artifacts.
6. Remaining risks or unverified behavior.
7. The next smallest recommended task.

Be precise about what is implemented, what is experimentally verified, and what remains proposed.

## 10. Repository boundaries

Public repository content should remain understandable to a new contributor with a fresh clone.

- Do not reference missing private planning files as mandatory dependencies.
- Do not commit files under the git-ignored `internal/` directory.
- Do not publish private credentials, internal research notes, or proprietary assets.
- Keep temporary agent workspace state outside tracked source files.

There is no permanent default assignment in this document. The current task is defined by the user's instructions and the applicable public project documentation.