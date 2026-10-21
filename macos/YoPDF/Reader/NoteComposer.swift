import AppKit
import SwiftUI
import YoPDFCore

/// One presentation of the note composer.
///
/// The mode decides what Save means. `create` carries the anchor that was
/// captured when the composer opened; `edit` carries the note that was clicked.
/// Both are values, so a stale composer can be recognised and refused by the
/// model instead of writing into whatever document is on screen by then.
struct NoteComposerPresentation: Identifiable {

    enum Mode {
        case create(NoteDraft)
        case edit(NoteSelection)
    }

    let id = UUID()
    let mode: Mode
    /// Where the popover's arrow should point, in the reader's top-left-origin
    /// space.
    let anchorRect: CGRect
    let pageLabel: String
    let excerpt: String?
    let initialContents: String
    let initialPaper: NotePaperColor

    init(mode: Mode, anchorRect: CGRect, pageLabel: String, excerpt: String?, contents: String, paper: NotePaperColor) {
        self.mode = mode
        self.anchorRect = anchorRect
        self.pageLabel = pageLabel
        self.excerpt = excerpt
        self.initialContents = contents
        self.initialPaper = paper
    }

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }
}

/// The compact note composer.
///
/// Nothing here writes to the PDF. The body and the paper colour are local state
/// until Save, which is what makes Cancel a true no-op: it cannot leave a dirty
/// document or an Undo entry behind, because no edit was ever made.
struct NoteComposerView: View {

    let presentation: NoteComposerPresentation
    @ObservedObject var model: PDFDocumentModel
    let onDismiss: () -> Void

    @State private var text: String
    @State private var paper: NotePaperColor
    @State private var isExpanded = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    init(
        presentation: NoteComposerPresentation,
        model: PDFDocumentModel,
        onDismiss: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.model = model
        self.onDismiss = onDismiss
        _text = State(initialValue: presentation.initialContents)
        _paper = State(initialValue: presentation.initialPaper)
    }

    /// Read from the model on every render: another application can change
    /// `/F` while the composer is open, and the Save button must follow.
    private var permissions: NotePermissions {
        switch presentation.mode {
        case .create:
            return model.canCreateNote
                ? NotePermissions(canEditContents: true, canChangeStyle: true, canDelete: true)
                : .none
        case let .edit(note):
            return model.notePermissions(for: note)
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedText.isEmpty && !permissions.isReadOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            editor
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
        .frame(width: isExpanded ? 420 : 344)
        .background(paperBackground)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                isFocused = true
            }
        }
        .onChange(of: isExpanded) { _, _ in
            isFocused = true
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.isEditing ? "Note" : "New Note")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ink.opacity(0.65))
                if let excerpt = presentation.excerpt, !excerpt.isEmpty {
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
                Text(presentation.pageLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ink.opacity(0.55))
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if isExpanded {
            TextEditor(text: $text)
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
            TextField("Write a note…", text: $text, axis: .vertical)
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

    private var palette: some View {
        HStack(spacing: 6) {
            ForEach(NotePaperColor.allCases, id: \.self) { candidate in
                Button {
                    paper = candidate
                } label: {
                    Circle()
                        .fill(Color(nsColor: candidate.color))
                        .frame(width: 17, height: 17)
                        .overlay {
                            Circle()
                                .strokeBorder(ink.opacity(paper == candidate ? 0.75 : 0.18), lineWidth: paper == candidate ? 2 : 1)
                        }
                        .padding(2)
                }
                .buttonStyle(.plain)
                .disabled(!permissions.canChangeStyle)
                .help(candidate.title)
                .accessibilityLabel(candidate.title)
                .accessibilityAddTraits(paper == candidate ? .isSelected : [])
            }

            Spacer(minLength: 4)

            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
                    .foregroundStyle(ink.opacity(0.65))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse the note" : "Expand to edit a long note")
            .accessibilityLabel(isExpanded ? "Collapse note editor" : "Expand note editor")
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if case let .edit(note) = presentation.mode, permissions.canDelete {
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

            Button(permissions.isReadOnly ? "Close" : "Cancel") {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(ink.opacity(0.7))

            if !permissions.isReadOnly {
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

    // MARK: - Actions

    private func save() {
        errorMessage = nil
        switch presentation.mode {
        case let .create(draft):
            switch model.addNote(draft, contents: text, paperColor: paper) {
            case .success:
                onDismiss()
            case let .failure(error):
                errorMessage = error.errorDescription
            }
        case let .edit(note):
            switch model.updateNote(note, contents: text, paperColor: paper) {
            case .success:
                onDismiss()
            case let .failure(error):
                errorMessage = error.errorDescription
            }
        }
    }

    // MARK: - Paper

    /// The sticky-note ink. Fixed rather than semantic because the paper is a
    /// light pastel in both appearances, so a dark-mode label colour would be
    /// unreadable on it.
    private var ink: Color { Color(red: 0.20, green: 0.18, blue: 0.14) }

    private var paperBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: paper.color))
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
