import SwiftUI
import YoPDFCore

/// The 540×560 expanded note editor, matching ShuaMac's sheet composer.
struct NoteStickerSheetEditor: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let onSave: (String, NoteStickerStyle, NoteTemplateSelection) -> String?

    @State private var text: String
    @State private var style: NoteStickerStyle
    @State private var templateSelection: NoteTemplateSelection
    @State private var errorMessage: String?

    init(
        title: String,
        text: String,
        style: NoteStickerStyle,
        templateSelection: NoteTemplateSelection = .init(),
        onSave: @escaping (String, NoteStickerStyle, NoteTemplateSelection) -> String?
    ) {
        self.title = title
        self.onSave = onSave
        _text = State(initialValue: text)
        _style = State(initialValue: style)
        _templateSelection = State(initialValue: templateSelection)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.headline)

            NoteStickerComposer(
                text: $text,
                style: $style,
                expanded: true,
                templateSelection: $templateSelection
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.62, green: 0.16, blue: 0.12))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedText.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540, height: 560)
    }

    private func save() {
        errorMessage = nil
        if let message = onSave(text, style, templateSelection) {
            errorMessage = message
            return
        }
        dismiss()
    }
}
