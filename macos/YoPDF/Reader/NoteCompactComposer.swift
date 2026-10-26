import SwiftUI
import YoPDFCore

/// ShuaMac's compact composer: sticker face, growing field, optional cancel,
/// draft actions and circular submit, all on the compact sticker paper.
struct NoteCompactComposer: View {
    @Binding var text: String
    @Binding var style: NoteStickerStyle
    @Binding var templateSelection: NoteTemplateSelection

    var canEditContents = true
    var canChangeStyle = true
    var canSubmit = true
    var showsCancel = false
    var submitSymbol = "checkmark"
    var submitTitle = "Save"
    var focusRequest = 0
    var onCancel: (() -> Void)?
    var onExpand: (() -> Void)?
    var onDelete: (() -> Void)?
    let onSubmit: () -> Void

    @State private var showsAppearance = false
    @FocusState private var isTextFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                showsAppearance.toggle()
            } label: {
                NoteStickerArtwork(motif: style.motif)
                    .frame(width: 29, height: 29)
            }
            .buttonStyle(ReaderInteractiveButtonStyle(insets: .init()))
            .disabled(!canChangeStyle)
            .help("Note appearance")
            .accessibilityLabel("Note appearance")
            .accessibilityIdentifier("pdf-note-appearance")
            .popover(isPresented: $showsAppearance, arrowEdge: .top) {
                NoteStickerStyleControls(
                    text: $text,
                    style: $style,
                    templateSelection: $templateSelection,
                    canEditContents: canEditContents
                )
                .padding(14)
                .frame(width: 330)
            }

            TextField("Write a note…", text: $text, axis: .vertical)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isTextFocused)
                .disabled(!canEditContents)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .accessibilityLabel("Note contents")
                .accessibilityIdentifier("pdf-compact-note-input")

            if showsCancel, let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 27)
                }
                .buttonStyle(ReaderInteractiveButtonStyle(insets: .init()))
                .foregroundStyle(.secondary)
                .help("Cancel")
                .accessibilityLabel("Cancel")
            }

            if onExpand != nil || onDelete != nil {
                Menu {
                    if let onExpand {
                        Button("Expand to Edit", systemImage: "arrow.up.left.and.arrow.down.right") {
                            onExpand()
                        }
                    }
                    if let onDelete {
                        if onExpand != nil { Divider() }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            onDelete()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 18, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Note actions")
                .accessibilityIdentifier("pdf-note-draft-actions")
            }

            Button {
                onSubmit()
                isTextFocused = true
            } label: {
                Image(systemName: submitSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 27, height: 27)
                    .background(
                        canSubmit ? Color.accentColor : Color.secondary.opacity(0.25),
                        in: Circle()
                    )
            }
            .buttonStyle(ReaderInteractiveButtonStyle(insets: .init()))
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(submitTitle)
            .help("\(submitTitle) (⌘↩)")
            .accessibilityIdentifier("pdf-compact-note-submit")
        }
        .noteStickerPaper(style, compact: true)
        .onAppear {
            isTextFocused = true
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "YOPDF_SCREENSHOT_APPEARANCE") {
                showsAppearance = true
            }
            #endif
        }
        .onChange(of: focusRequest) { _, _ in isTextFocused = true }
        .onChange(of: showsAppearance) { _, shown in
            if !shown { isTextFocused = true }
        }
    }
}
