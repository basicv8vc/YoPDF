import AppKit
import SwiftUI
import YoPDFCore

/// A Finder-style grid of recent documents for the reader's empty state.
///
/// The grid is a block centred on the same vertical axis as the welcome icon
/// and the Open PDF button. Each cell is a fixed-width container: the page
/// outline and the two-line filename are centred *inside* that container, so
/// the eye can scan the grid instead of hunting for the start of each line.
struct RecentDocumentsGrid: View {
    @ObservedObject var store: RecentDocumentsStore
    let onOpen: (RecentDocument) -> Void
    let onRelink: (RecentDocument) -> Void

    private static let maximumItems = 5

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Text("Recent Documents")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 118, maximum: 152), spacing: 16)],
                spacing: 18
            ) {
                ForEach(Array(store.items.prefix(Self.maximumItems))) { item in
                    RecentDocumentCell(
                        item: item,
                        store: store,
                        onOpen: onOpen,
                        onRelink: onRelink
                    )
                }
            }
        }
        .frame(maxWidth: 760, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct RecentDocumentCell: View {
    /// The fixed box every preview is centred in, regardless of page ratio.
    private static let previewBox = CGSize(width: 96, height: 124)

    let item: RecentDocument
    @ObservedObject var store: RecentDocumentsStore
    let onOpen: (RecentDocument) -> Void
    let onRelink: (RecentDocument) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            onOpen(item)
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    pagePreview
                    if isNew {
                        Text("NEW")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: -4, y: 6)
                    }
                }

                VStack(spacing: 2) {
                    Text(item.displayName)
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text(readingPositionLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6))
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(item.lastKnownPath)
        .accessibilityLabel("Open \(item.displayName)")
        .contextMenu {
            Button("Show in Finder") {
                guard let url = try? store.resolveURL(for: item) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Choose File…") {
                onRelink(item)
            }
            Divider()
            Button("Remove from Recents", role: .destructive) {
                store.remove(item)
            }
        }
    }

    /// The white page outline keeps a stable shape while a document is loading;
    /// the real first-page image is fitted inside it without stretching.
    private var pagePreview: some View {
        let outline = fittedSize(CGSize(width: 3, height: 4))
        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white)
            Image(systemName: "doc.richtext")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
        }
        .frame(width: outline.width, height: outline.height)
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.black.opacity(0.14), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
        .frame(width: Self.previewBox.width, height: Self.previewBox.height)
    }

    private func fittedSize(_ original: CGSize) -> CGSize {
        guard original.width > 0, original.height > 0 else { return Self.previewBox }
        let scale = min(
            Self.previewBox.width / original.width,
            Self.previewBox.height / original.height
        )
        return CGSize(width: original.width * scale, height: original.height * scale)
    }

    private var isNew: Bool {
        Date.now.timeIntervalSince(item.lastOpenedAt) < 24 * 60 * 60
    }

    private var readingPositionLabel: String {
        let pageIndex = item.readingPosition.pageIndex
        return pageIndex > 0 ? "Page \(pageIndex + 1)" : " "
    }
}
