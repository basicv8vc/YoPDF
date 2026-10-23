import AppKit
import SwiftUI
import YoPDFCore

/// The note popover.
///
/// Nothing here writes to the PDF until Save. The body and the complete sticker
/// style live in `NoteComposerSession`, not in this view's state, so closing and
/// rebuilding the popover cannot throw the draft away.
struct NoteComposerView: View {

    @ObservedObject var session: NoteComposerSession
    @ObservedObject var model: PDFDocumentModel
    let onDismiss: () -> Void

    /// A failure reported by the last Save. Local on purpose: it describes one
    /// attempt, and the text it failed to save is not local state.
    @State private var errorMessage: String?
    @State private var showsExpandedEditor = false
    @State private var expandedEditorSnapshot: NoteComposerSession.Snapshot?
    @State private var focusRequest = 0
    #if DEBUG
    @State private var didAutoPresentScreenshotSurface = false
    #endif

    /// Read from the model on every render: another application can change `/F`
    /// while the composer is open, and the Save button must follow.
    private var permissions: NotePermissions {
        switch session.mode {
        case .create:
            return model.canCreateNote
                ? NotePermissions(canEditContents: true, canChangeStyle: true, canDelete: true)
                : .none
        case let .edit(note):
            return model.notePermissions(for: note)
        }
    }

    /// Whether the note this composer is working on is still there.
    private var status: NoteDraftStatus {
        session.status(in: model)
    }

    private var trimmedText: String {
        session.contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        status.isReady && !trimmedText.isEmpty && !permissions.isReadOnly
    }

    private var additionalGroupNotes: [String] {
        guard case let .edit(note) = session.mode, note.groupCount > 1 else { return [] }
        return Array(note.threadContents.dropFirst())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !additionalGroupNotes.isEmpty {
                DisclosureGroup("Other notes in this group (\(additionalGroupNotes.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(additionalGroupNotes.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 2)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, alignment: .trailing)
                                Text(additionalGroupNotes[index].isEmpty
                                    ? "Empty note"
                                    : additionalGroupNotes[index])
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.top, 5)
                }
                .font(.caption)
            }

            if !status.isReady {
                detachedNotice
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.62, green: 0.16, blue: 0.12))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if permissions.isReadOnly {
                readOnlyCard
            } else {
                NoteCompactComposer(
                    text: $session.contents,
                    style: styleBinding,
                    templateSelection: templateSelectionBinding,
                    canEditContents: permissions.canEditContents,
                    canChangeStyle: permissions.canChangeStyle,
                    canSubmit: canSave,
                    showsCancel: session.isEditing,
                    submitSymbol: session.isEditing ? "checkmark" : "arrow.up",
                    submitTitle: session.isEditing ? "Save" : "Add",
                    focusRequest: focusRequest,
                    onCancel: session.isEditing ? onDismiss : nil,
                    onExpand: { beginExpandedEditor() },
                    onDelete: deleteAction,
                    onSubmit: { save() }
                )
            }
        }
        .padding(14)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("pdf-thought-capture-popover")
        .onAppear {
            #if DEBUG
            guard !didAutoPresentScreenshotSurface else { return }
            didAutoPresentScreenshotSurface = true
            if UserDefaults.standard.bool(forKey: "YOPDF_SCREENSHOT_EXPANDED") {
                showsExpandedEditor = true
            }
            #endif
        }
        .sheet(isPresented: $showsExpandedEditor, onDismiss: {
            expandedEditorSnapshot = nil
            focusRequest += 1
        }) {
            NoteStickerSheetEditor(
                title: session.isEditing ? "Edit Note" : "New Note",
                text: $session.contents,
                style: $session.style,
                templateSelection: templateSelectionBinding,
                canEditContents: permissions.canEditContents,
                canChangeStyle: permissions.canChangeStyle,
                onCancel: cancelExpandedEditor,
                onSave: saveExpanded
            )
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(session.excerpt.flatMap { $0.isEmpty ? nil : $0 } ?? "Page note")
                .font(.callout)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(session.pageLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()

            if permissions.isContentsLocked {
                Image(systemName: "lock.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("This note’s text is locked. Its sticker and colour can still be changed.")
            }

            if !session.isEditing || permissions.isReadOnly {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.borderless)
                .help(permissions.isReadOnly ? "Close this note" : "Cancel")
                .accessibilityLabel(permissions.isReadOnly ? "Close" : "Cancel")
            }
        }
    }

    /// A read-only note is still readable in the same paper treatment. There is
    /// no disabled submit button pretending that a write is possible.
    private var readOnlyCard: some View {
        HStack(alignment: .top, spacing: 9) {
            NoteStickerArtwork(motif: session.style.motif)
                .frame(width: 29, height: 29)
            Text(session.contents)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .noteStickerPaper(session.style, compact: true)
    }

    /// Shown when the note has gone away — deleted, undone, or left behind by a
    /// document that was replaced.
    ///
    /// The text is deliberately still here. Nothing is redirected to another
    /// note, because there is no way to know which note the user meant.
    private var detachedNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detachedMessage)
                .font(.caption)
                .foregroundStyle(Color(red: 0.62, green: 0.16, blue: 0.12))
                .fixedSize(horizontal: false, vertical: true)
            if !trimmedText.isEmpty {
                Button("Copy Text") {
                    copyContents()
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Copy the note’s text so it is not lost")
            }
        }
    }

    private var detachedMessage: String {
        switch status {
        case .ready:
            return ""
        case .documentReplaced:
            return "This note was started in a document that is no longer open. Your text is still here — copy it, or cancel."
        case .noteRemoved:
            return "This note is no longer in the document. Your text is still here — copy it, or cancel."
        case .commentingDisabled:
            return "This document no longer accepts notes. Your text is still here — copy it, or cancel."
        }
    }

    // MARK: - Bindings

    private var styleBinding: Binding<NoteStickerStyle> {
        Binding(
            get: { session.style },
            set: { session.style = $0 }
        )
    }

    private var templateSelectionBinding: Binding<NoteTemplateSelection> {
        Binding(
            get: { session.templateSelection },
            set: { session.templateSelection = $0 }
        )
    }

    // MARK: - Actions

    private func save() {
        errorMessage = nil
        switch session.commit(to: model) {
        case .success:
            onDismiss()
        case let .failure(error):
            errorMessage = error.errorDescription
        }
    }

    private func beginExpandedEditor() {
        expandedEditorSnapshot = session.snapshot()
        showsExpandedEditor = true
    }

    /// Cancel returns to the compact draft as it stood when the sheet opened.
    /// The session has already tracked every expanded edit for close and quit
    /// protection, so restoring through it also invalidates stale approvals.
    private func cancelExpandedEditor() {
        if let expandedEditorSnapshot {
            session.restore(from: expandedEditorSnapshot)
        }
        expandedEditorSnapshot = nil
        showsExpandedEditor = false
    }

    /// The sheet edits the session live; Save commits that same protected draft.
    /// Returning a message keeps the sheet open with every edit intact on failure.
    private func saveExpanded() -> String? {
        errorMessage = nil

        switch session.commit(to: model) {
        case .success:
            expandedEditorSnapshot = nil
            onDismiss()
            return nil
        case let .failure(error):
            let message = error.errorDescription ?? "The note was not saved."
            errorMessage = message
            return message
        }
    }

    private var deleteAction: (() -> Void)? {
        guard case let .edit(note) = session.mode,
              permissions.canDelete,
              status.isReady
        else { return nil }
        return {
            if model.deleteNote(note) {
                onDismiss()
            } else {
                errorMessage = NoteEditError.permissionDenied.errorDescription
            }
        }
    }

    private func copyContents() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.contents, forType: .string)
    }
}
