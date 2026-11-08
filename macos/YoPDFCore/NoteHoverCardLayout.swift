import CoreGraphics

/// Where a note hover card goes, and how much of a thread it can hold.
///
/// The card is drawn inside the page overlay, next to the sticker it describes,
/// so it must never leave the page and must never cover the sticker when there
/// is room to sit above it. Both rules live here as plain geometry: the reader
/// only supplies measured sizes and a page rectangle, which keeps the placement
/// testable without a window, a PDF or a running application.
public enum NoteHoverCardLayout {

    /// Distance between the sticker and the card.
    public static let gap: CGFloat = 8
    /// Smallest distance between the card and the edge of the page.
    public static let inset: CGFloat = 6

    /// Places `cardSize` above `stickerFrame`, below it when the page edge is in
    /// the way, and inside `container` in every case.
    ///
    /// "Above" is the reader's visual top: the overlay is not flipped, so a
    /// larger `y` is higher on the page. The card is clamped into the container
    /// rather than allowed to overflow it, because a page overlay clips its own
    /// drawing and subviews.
    public static func frame(
        cardSize: CGSize,
        stickerFrame: CGRect,
        container: CGRect,
        gap: CGFloat = NoteHoverCardLayout.gap,
        inset: CGFloat = NoteHoverCardLayout.inset
    ) -> CGRect {
        guard cardSize.width.isFinite, cardSize.height.isFinite,
              container.width.isFinite, container.height.isFinite
        else { return .zero }

        let usable = container.insetBy(dx: inset, dy: inset)
        guard usable.width > 0, usable.height > 0 else { return .zero }

        let width = min(cardSize.width, usable.width)
        let height = min(cardSize.height, usable.height)
        guard width > 0, height > 0 else { return .zero }

        // Prefer above the sticker. Flip below only when the card would leave
        // the container, and otherwise settle for the closest legal position:
        // a card that overlaps the sticker is still better than no card.
        let above = stickerFrame.maxY + gap
        let below = stickerFrame.minY - gap - height
        var y: CGFloat
        if above + height <= usable.maxY {
            y = above
        } else if below >= usable.minY {
            y = below
        } else {
            y = above
        }
        // The sticker itself may sit partly outside the container (a page
        // scrolled to its edge), so both branches still have to be clamped.
        y = min(max(y, usable.minY), usable.maxY - height)

        let centered = stickerFrame.midX - width / 2
        let x = min(max(centered, usable.minX), usable.maxX - width)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// How many measured entries fit in `availableHeight`.
    ///
    /// Entries are shown whole, in thread order, with `separatorHeight` between
    /// neighbours. Returning a prefix count instead of a height keeps the card
    /// from cutting a note mid-sentence when the thread is simply too long: the
    /// reader draws the entries that fit and says how many are left.
    ///
    /// A result of zero means not even the first entry fits; the caller decides
    /// whether to clip it or skip the card entirely.
    public static func visibleEntryCount(
        entryHeights: [CGFloat],
        separatorHeight: CGFloat,
        availableHeight: CGFloat
    ) -> Int {
        guard availableHeight > 0, separatorHeight >= 0 else { return 0 }

        var used: CGFloat = 0
        var count = 0
        for height in entryHeights {
            guard height.isFinite else { break }
            // A zero-height entry (an unmeasurable body) takes no room but still
            // counts as a row, so the caller's prefix stays aligned with its own
            // text list.
            let needed = used + (count == 0 ? 0 : separatorHeight) + max(height, 0)
            guard needed <= availableHeight else { break }
            used = needed
            count += 1
        }
        return count
    }
}
