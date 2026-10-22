import AppKit
import SwiftUI
import YoPDFCore

/// The original sticker artwork. Simple Paper has no bitmap, so it falls back
/// to the same brown SF Symbol ShuaMac uses.
struct NoteStickerArtwork: View {
    let motif: NoteMotif

    var body: some View {
        Group {
            if let name = motif.assetName,
               let image = NSImage(named: NSImage.Name(name)) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "note.text")
                    .resizable()
                    .scaledToFit()
                    .padding(7)
                    .foregroundStyle(Color(red: 0.44, green: 0.31, blue: 0.24))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A cream paper sticker with a white die-cut edge, a little washi tape and
/// original artwork. Ported from ShuaMac's `MacPDFStickerPaper`.
struct NoteStickerPaper: ViewModifier {
    let style: NoteStickerStyle
    var compact = false

    private var collection: NoteStickerCollection { style.motif.collection }
    private var cornerRadius: CGFloat {
        collection == .vintage ? 5 : (compact ? 11 : 17)
    }

    private var ink: Color { Color(red: 0.25, green: 0.20, blue: 0.17) }
    private var warmInk: Color { Color(red: 0.44, green: 0.31, blue: 0.24) }
    private var vintagePaper: Color { Color(red: 0.98, green: 0.95, blue: 0.88) }
    private var paletteColor: Color { Color(nsColor: style.palette.color) }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(ink)
            .padding(compact ? 10 : 16)
            .padding(.top, compact ? 0 : 9)
            .background(paperBackground)
            .overlay(whiteDieCut)
            .overlay(dashedBorder)
            .overlay(alignment: .topLeading) { washiTape }
            .overlay(alignment: .topTrailing) { cornerArtwork }
            .shadow(
                color: Color(red: 0.37, green: 0.26, blue: 0.21)
                    .opacity(compact ? 0.06 : 0.10),
                radius: compact ? 2 : 4,
                x: 0,
                y: compact ? 1 : 2
            )
    }

    private var paperBackground: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(collection == .vintage ? vintagePaper : .white)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(paletteColor.opacity(0.32))
            }
    }

    private var whiteDieCut: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(.white, lineWidth: compact ? 2 : 4)
    }

    @ViewBuilder
    private var dashedBorder: some View {
        if collection == .doodle || collection == .vintage {
            RoundedRectangle(cornerRadius: max(2, cornerRadius - 4))
                .strokeBorder(
                    warmInk.opacity(0.16),
                    style: StrokeStyle(lineWidth: 0.8, dash: [2, 4])
                )
                .padding(7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var washiTape: some View {
        if !compact && [.cream, .pets, .animals, .vintage].contains(collection) {
            RoundedRectangle(cornerRadius: 2)
                .fill(paletteColor.opacity(0.80))
                .frame(width: 56, height: 13)
                .rotationEffect(.degrees(-5))
                .offset(x: 22, y: -5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var cornerArtwork: some View {
        if !compact && style.motif != .plain {
            NoteStickerArtwork(motif: style.motif)
                .frame(width: 43, height: 43)
                .rotationEffect(.degrees(7))
                .offset(x: 5, y: -14)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func noteStickerPaper(_ style: NoteStickerStyle, compact: Bool = false) -> some View {
        modifier(NoteStickerPaper(style: style, compact: compact))
    }
}

/// The rounded caption inside an expanded sticker. Empty title means "Note".
struct NoteStickerHeading: View {
    let style: NoteStickerStyle

    var body: some View {
        Text(style.displayTitle.isEmpty ? "Note" : style.displayTitle)
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .foregroundStyle(Color(red: 0.44, green: 0.31, blue: 0.24))
            .padding(.trailing, 32)
    }
}

/// Collection selector and a horizontal row of real artwork thumbnails.
struct NoteStickerMotifPicker: View {
    @Binding var selection: NoteMotif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var collection: Binding<NoteStickerCollection> {
        Binding(
            get: { selection.collection },
            set: { newValue in
                if selection.collection != newValue,
                   let first = newValue.motifs.first {
                    selection = first
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Sticker")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Sticker Collection", selection: collection) {
                    ForEach(NoteStickerCollection.allCases, id: \.self) { group in
                        Text(group.title).tag(group)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            HStack(spacing: 7) {
                ForEach(selection.collection.motifs, id: \.self) { motif in
                    Button {
                        selection = motif
                    } label: {
                        VStack(spacing: 3) {
                            NoteStickerArtwork(motif: motif)
                                .frame(width: 32, height: 32)
                            Text(motif.title)
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(5)
                        .background {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(selection == motif ? Color.accentColor.opacity(0.08) : .clear)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    selection == motif ? Color.accentColor.opacity(0.5) : .clear
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(motif.title)
                    .accessibilityAddTraits(selection == motif ? .isSelected : [])
                }
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.15),
            value: selection
        )
    }
}

/// Template menu, six palette swatches, collection and motif picker.
///
/// The seed lives in the composer session, not in this popover, so closing the
/// popover cannot turn an untouched template outline into user text.
struct NoteStickerStyleControls: View {
    @Binding var text: String
    @Binding var style: NoteStickerStyle
    @ObservedObject private var library = NoteTemplateStore.shared
    @Binding var templateSelection: NoteTemplateSelection

    @State private var showsLibrary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu {
                    Section("Built-in Templates") {
                        ForEach(NoteTemplate.builtIns()) { template in
                            Button {
                                apply(template)
                            } label: {
                                Label(template.style.displayTitle, systemImage: template.style.symbol)
                            }
                        }
                    }
                    if !library.templates.isEmpty {
                        Section("My Templates") {
                            ForEach(library.templates) { template in
                                Button(template.style.displayTitle) {
                                    apply(template)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Manage Templates…") { showsLibrary = true }
                } label: {
                    Label("Templates", systemImage: "square.stack")
                }
                .fixedSize()
                .accessibilityIdentifier("pdf-sticker-templates")

                Spacer()

                HStack(spacing: 5) {
                    ForEach(NotePaperColor.allCases, id: \.self) { palette in
                        Button {
                            style.palette = palette
                        } label: {
                            Circle()
                                .fill(Color(nsColor: palette.color))
                                .frame(width: 15, height: 15)
                                .overlay {
                                    Circle().strokeBorder(
                                        style.palette == palette ? Color.primary : .clear,
                                        lineWidth: 2
                                    )
                                }
                                .padding(2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(palette.title)
                        .accessibilityAddTraits(style.palette == palette ? .isSelected : [])
                    }
                }
            }

            NoteStickerMotifPicker(selection: Binding(
                get: { style.motif },
                set: { style.motif = $0 }
            ))
        }
        .onAppear {
            templateSelection.restoreIfNeeded(
                text: text,
                templates: NoteTemplate.builtIns() + library.templates
            )
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "YOPDF_SCREENSHOT_TEMPLATES") {
                showsLibrary = true
            }
            #endif
        }
        .sheet(isPresented: $showsLibrary) {
            NoteTemplateLibrary(seedText: text, seedStyle: style, onUse: apply)
        }
    }

    private func apply(_ template: NoteTemplate) {
        text = templateSelection.apply(template, to: text)
        style = template.style
    }
}

/// The full composer used by the 540×560 sheet editor.
struct NoteStickerComposer: View {
    @Binding var text: String
    @Binding var style: NoteStickerStyle
    var expanded = false
    @Binding var templateSelection: NoteTemplateSelection
    var canEditContents = true
    var canChangeStyle = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isTextFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NoteStickerStyleControls(
                text: $text,
                style: $style,
                templateSelection: $templateSelection
            )
            .disabled(!canChangeStyle)

            VStack(alignment: .leading, spacing: 9) {
                NoteStickerHeading(style: style)
                if canEditContents {
                    TextEditor(text: $text)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 0.20, green: 0.18, blue: 0.14))
                        .scrollContentBackground(.hidden)
                        .frame(
                            minHeight: expanded ? 220 : 90,
                            maxHeight: expanded ? .infinity : 150
                        )
                        .accessibilityLabel("Note contents")
                        .accessibilityIdentifier("pdf-sticker-text")
                        .focused($isTextFocused)
                } else {
                    ScrollView(.vertical) {
                        Text(text)
                            .font(.system(size: 14))
                            .foregroundStyle(Color(red: 0.20, green: 0.18, blue: 0.14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .accessibilityLabel("Note contents")
                            .accessibilityIdentifier("pdf-sticker-text")
                    }
                    .frame(
                        minHeight: expanded ? 220 : 90,
                        maxHeight: expanded ? .infinity : 150
                    )
                }
            }
            .noteStickerPaper(style)
            .padding(.top, 10)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: style.palette)
        }
        .onAppear {
            if canEditContents { isTextFocused = true }
        }
    }
}
