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

    /// Short windows use smaller page previews so both rows stay visible.
    var compact = false

    /// The store keeps ten items; showing all of them is two rows at the
    /// default window width (five adaptive columns per row).
    private static let maximumItems = 10

    var body: some View {
        VStack(alignment: .center, spacing: compact ? 8 : 14) {
            Text("Recent Documents")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 118, maximum: 152), spacing: 16)],
                spacing: compact ? 10 : 18
            ) {
                ForEach(Array(store.items.prefix(Self.maximumItems))) { item in
                    RecentDocumentCell(
                        item: item,
                        store: store,
                        onOpen: onOpen,
                        onRelink: onRelink,
                        compact: compact
                    )
                }
            }
        }
        .frame(maxWidth: 760, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
        // Cache pruning follows the recent list itself (wired in AppDelegate),
        // so it also runs when this grid — or every window — is gone.
    }
}

private struct RecentDocumentCell: View {
    /// The fixed box every preview is centred in, regardless of page ratio.
    private static let regularPreviewBox = CGSize(width: 96, height: 124)
    private static let compactPreviewBox = CGSize(width: 70, height: 92)

    let item: RecentDocument
    @ObservedObject var store: RecentDocumentsStore
    let onOpen: (RecentDocument) -> Void
    let onRelink: (RecentDocument) -> Void
    let compact: Bool

    @State private var isHovered = false
    @State private var image: NSImage?

    private var previewBox: CGSize {
        compact ? Self.compactPreviewBox : Self.regularPreviewBox
    }

    var body: some View {
        Button {
            onOpen(item)
        } label: {
            VStack(spacing: compact ? 5 : 8) {
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
            .padding(EdgeInsets(
                top: compact ? 4 : 8,
                leading: 6,
                bottom: compact ? 4 : 8,
                trailing: 6
            ))
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .task(id: RecentDocumentThumbnailCachePolicy.renderIdentity(for: item)) {
            // Resolving the bookmark is main-actor work; rendering happens in
            // the provider's actor and never blocks the empty state. The task
            // identity includes the path and bookmark fingerprint, so a relink
            // (which keeps the entry's UUID) reloads the preview everywhere.
            let url = try? store.resolveURL(for: item)
            image = await RecentDocumentThumbnailProvider.shared.image(
                for: item, url: url
            )
        }
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

    /// The first page is fitted to the page's real ratio inside a fixed box,
    /// so portrait, landscape and slide decks all stay centred like Finder's
    /// icon view. A missing or unreadable file keeps the generic outline.
    private var pagePreview: some View {
        let outline = fittedSize(image?.size ?? CGSize(width: 3, height: 4))
        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "doc.richtext")
                    .font(.system(size: compact ? 18 : 24, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: outline.width, height: outline.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.black.opacity(0.14), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
        .frame(width: previewBox.width, height: previewBox.height)
    }

    private func fittedSize(_ original: CGSize) -> CGSize {
        guard original.width > 0, original.height > 0 else { return previewBox }
        let scale = min(
            previewBox.width / original.width,
            previewBox.height / original.height
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
