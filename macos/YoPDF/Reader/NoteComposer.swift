import AppKit
import SwiftUI
import YoPDFCore

/// The compact note composer.
///
/// Nothing here writes to the PDF. The body and the paper colour live in the
/// `NoteComposerSession`, not in this view's state, so Save is still the only
/// thing that mutates the document — which is what makes Cancel a true no-op —
/// while rebuilding the popover cannot throw the text away.
struct NoteComposerView: View {

    @ObservedObject var session: NoteComposerSession
    @ObservedObject var model: PDFDocumentModel
    let onDismiss: () -> Void

    /// A failure reported by the last Save. Local on purpose: it describes one
    /// attempt, and the text it failed to save is not local state.
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            editor
            if !status.isReady {
                detachedNotice
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.62, green: 0.16, blue: 0.12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            palette
            buttons
        }
        .padding(14)
        .frame(width: session.isExpanded ? 420 : 344)
        .background(paperBackground)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                isFocused = true
            }
        }
        .onChange(of: session.isExpanded) { _, _ in
            isFocused = true
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.isEditing ? "Note" : "New Note")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ink.opacity(0.65))
                if let excerpt = session.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.callout)
                        .foregroundStyle(ink.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Page note")
                        .font(.callout)
                        .foregroundStyle(ink.opacity(0.6))
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                if permissions.isContentsLocked {
                    Image(systemName: "lock.doc")
                        .font(.caption)
                        .help("This note’s text is locked. Its colour can still be changed.")
                } else if permissions.isReadOnly {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .help("This note is protected and cannot be changed.")
                }
                Text(session.pageLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ink.opacity(0.55))
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if session.isExpanded {
            TextEditor(text: $session.contents)
                .font(.system(size: 13))
                .foregroundStyle(ink)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .disabled(!permissions.canEditContents)
                .frame(minHeight: 190, maxHeight: 190)
                .padding(6)
                .background(fieldBackground)
                .accessibilityLabel("Note contents")
                .accessibilityIdentifier("note-composer-input")
        } else {
            // A vertical TextField grows with its content and scrolls internally
            // after the limit, which is exactly the four-line behaviour the
            // compact composer wants. Return inserts a newline; ⌘Return submits.
            TextField("Write a note…", text: $session.contents, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(ink)
                .lineLimit(1...4)
                .focused($isFocused)
                .disabled(!permissions.canEditContents)
                .padding(6)
                .background(fieldBackground)
                .accessibilityLabel("Note contents")
                .accessibilityIdentifier("note-composer-input")
        }
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

    private var palette: some View {
        HStack(spacing: 6) {
            ForEach(NotePaperColor.allCases, id: \.self) { candidate in
                Button {
                    session.paper = candidate
                } label: {
                    Circle()
                        .fill(Color(nsColor: candidate.color))
                        .frame(width: 17, height: 17)
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    ink.opacity(session.paper == candidate ? 0.75 : 0.18),
                                    lineWidth: session.paper == candidate ? 2 : 1
                                )
                        }
                        .padding(2)
                }
                .buttonStyle(.plain)
                .disabled(!permissions.canChangeStyle)
                .help(candidate.title)
                .accessibilityLabel(candidate.title)
                .accessibilityAddTraits(session.paper == candidate ? .isSelected : [])
            }

            Spacer(minLength: 4)

            Button {
                session.isExpanded.toggle()
            } label: {
                Image(systemName: session.isExpanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
                    .foregroundStyle(ink.opacity(0.65))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.plain)
            .help(session.isExpanded ? "Collapse the note" : "Expand to edit a long note")
            .accessibilityLabel(session.isExpanded ? "Collapse note editor" : "Expand note editor")
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if case let .edit(note) = session.mode, permissions.canDelete, status.isReady {
                Button("Delete") {
                    if model.deleteNote(note) {
                        onDismiss()
                    } else {
                        errorMessage = NoteEditError.permissionDenied.errorDescription
                    }
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(Color(red: 0.62, green: 0.16, blue: 0.12))
                .help("Delete this note (⌘Z brings it back)")
            }

            Spacer(minLength: 4)

            Button(dismissTitle) {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(ink.opacity(0.7))
            .help(dismissHelp)

            if !permissions.isReadOnly && status.isReady {
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canSave)
                .help("Save the note (⌘↩)")
            }
        }
    }

    /// A draft with text that can no longer be saved is discarded by an explicit
    /// choice, not by a button that looks like "Close".
    private var dismissTitle: String {
        if !status.isReady, !trimmedText.isEmpty { return "Discard Draft" }
        return permissions.isReadOnly ? "Close" : "Cancel"
    }

    private var dismissHelp: String {
        if !status.isReady, !trimmedText.isEmpty {
            return "Discard this draft. Use Copy Text first to keep the text."
        }
        return permissions.isReadOnly ? "Close this note" : "Close without saving"
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

    private func copyContents() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.contents, forType: .string)
    }

    // MARK: - Paper

    /// The sticky-note ink. Fixed rather than semantic because the paper is a
    /// light pastel in both appearances, so a dark-mode label colour would be
    /// unreadable on it.
    private var ink: Color { Color(red: 0.20, green: 0.18, blue: 0.14) }

    private var paperBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: session.paper.color))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(ink.opacity(0.14), lineWidth: 1)
            }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(0.55))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(ink.opacity(0.10), lineWidth: 1)
            }
    }
}
