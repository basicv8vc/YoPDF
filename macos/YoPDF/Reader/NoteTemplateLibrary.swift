import SwiftUI
import YoPDFCore

/// The 760×590 template library: browse built-ins and personal templates,
/// edit their appearance and outline, and apply one to the draft.
struct NoteTemplateLibrary: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = NoteTemplateStore.shared

    let seedText: String
    let seedStyle: NoteStickerStyle
    let onUse: (NoteTemplate) -> Void

    @State private var selectedID: String?
    @State private var name = ""
    @State private var bodyText = ""
    @State private var palette = NotePaperColor.honey
    @State private var symbol = NoteStickerStyle.defaultSymbol
    @State private var motif = NoteMotif.bunny
    @State private var error = false
    @State private var confirmsDelete = false

    private var selected: NoteTemplate? {
        (NoteTemplate.builtIns() + library.templates).first { $0.id == selectedID }
    }

    private var isCustom: Bool {
        library.templates.contains { $0.id == selectedID }
    }

    private var draft: NoteTemplate {
        NoteTemplate(
            id: selectedID ?? UUID().uuidString,
            style: NoteStickerStyle(
                motif: motif,
                palette: palette,
                title: name,
                symbol: symbol
            ),
            body: bodyText
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Note Templates")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            HStack(spacing: 0) {
                List(selection: $selectedID) {
                    Section("Built-in Templates") {
                        ForEach(NoteTemplate.builtIns()) { template in
                            HStack(spacing: 8) {
                                NoteStickerArtwork(motif: template.style.motif)
                                    .frame(width: 26, height: 26)
                                Text(template.style.displayTitle)
                            }
                            .tag(template.id)
                        }
                    }
                    Section("My Templates") {
                        ForEach(library.templates) { template in
                            HStack(spacing: 8) {
                                NoteStickerArtwork(motif: template.style.motif)
                                    .frame(width: 26, height: 26)
                                Text(template.style.displayTitle)
                            }
                            .tag(template.id)
                        }
                    }
                }
                .frame(width: 210)
                .onChange(of: selectedID) { _, _ in
                    if let selected { load(selected) }
                }

                Divider()

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Template name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("New Template", systemImage: "plus") {
                            selectedID = nil
                            name = ""
                            bodyText = seedText
                            palette = seedStyle.palette
                            symbol = seedStyle.symbol
                            motif = seedStyle.motif
                        }
                    }

                    TextField("Template name", text: $name)
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading, spacing: 10) {
                        NoteStickerHeading(style: draft.style)
                        TextEditor(text: $bodyText)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .accessibilityLabel("Template outline")
                    }
                    .noteStickerPaper(draft.style)

                    NoteStickerMotifPicker(selection: $motif)

                    Picker("Paper color", selection: $palette) {
                        ForEach(NotePaperColor.allCases, id: \.self) { color in
                            Text(color.title).tag(color)
                        }
                    }

                    HStack {
                        if isCustom {
                            Button("Delete", role: .destructive) {
                                confirmsDelete = true
                            }
                        }
                        Spacer()
                        Button(isCustom ? "Save Changes" : "Save as Template") {
                            save()
                        }
                        .disabled(
                            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || library.loadFailed
                        )
                        Button("Use Template") {
                            onUse(draft)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 760, height: 590)
        .onAppear {
            name = seedStyle.title
            bodyText = seedText
            palette = seedStyle.palette
            symbol = seedStyle.symbol
            motif = seedStyle.motif
            error = library.loadFailed
        }
        .confirmationDialog("Delete this template?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) {
                guard let selectedID else { return }
                do {
                    try library.delete(id: selectedID)
                    self.selectedID = nil
                } catch {
                    self.error = true
                }
            }
        } message: {
            Text("Existing notes will keep their appearance.")
        }
        .alert("Template library unavailable", isPresented: $error) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your saved templates could not be updated. The original library has been kept.")
        }
    }

    private func load(_ template: NoteTemplate) {
        name = template.style.title
        bodyText = template.body
        palette = template.style.palette
        symbol = template.style.symbol
        motif = template.style.motif
    }

    private func save() {
        do {
            let saved = try library.save(
                id: isCustom ? selectedID : nil,
                style: draft.style,
                body: bodyText
            )
            selectedID = saved.id
        } catch {
            self.error = true
        }
    }
}
