import AppKit
import YoPDFCore

/// The card a note sticker shows while the pointer rests on it.
///
/// A sticker only says "there is a note here": reading it used to require a
/// click and a popover. This card shows the same body above the sticker
/// instead. It is a subview of the page overlay, so it scrolls, zooms and
/// rotates with the page like the sticker does, and it refuses hit testing so
/// hovering never interferes with selecting text, dragging the sticker or
/// opening the note.
///
/// A sticker can carry a whole thread of notes. Every entry is drawn in thread
/// order with its own paper colour as a number badge, and when the thread does
/// not fit the card says how many notes are left rather than cutting one
/// mid-sentence.
///
/// The card is a container: a backdrop (Liquid Glass on macOS 26 and later, the
/// painted paper on older systems) plus a content layer that draws the text on
/// top of it. Splitting the two is what lets the glass sit behind the text,
/// since a view always draws its own content above its subviews.
@MainActor
final class NoteHoverCardView: NSView {

    /// Below this width the card cannot show a readable column of text, so the
    /// reader skips it instead of covering the page with a sliver.
    static let minimumWidth: CGFloat = 168
    static let preferredWidth: CGFloat = 268
    static let maximumHeight: CGFloat = 236

    var preview: NoteHoverPreview? {
        didSet {
            contentView.preview = preview
            paperView.preview = preview
            applyGlassTint()
        }
    }

    /// The size `preview` needs, already clamped to the caller's limits.
    ///
    /// Measuring and drawing share one layout pass, so the drawn card is exactly
    /// the size the caller placed.
    static func size(
        for preview: NoteHoverPreview,
        width: CGFloat,
        maxHeight: CGFloat
    ) -> CGSize {
        CardLayout(preview: preview, width: width, maxHeight: maxHeight).size
    }

    private let contentView = NoteHoverCardContentView()
    private let paperView = NoteHoverCardPaperView()

    /// Present only on macOS 26 and later, where AppKit provides the system
    /// glass material. `nil` means the painted paper backdrop is in use.
    private var glassView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildBackdrop()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Text is laid out top-down, so a card row reads like a paragraph.
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// Hover is read-only: the card must never take the click that opens the
    /// note or the drag that moves the sticker.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        paperView.frame = bounds
        glassView?.frame = bounds
        contentView.frame = bounds
    }

    // MARK: - Backdrop

    private func buildBackdrop() {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = CardMetrics.cornerRadius
            // The content has to go through `contentView`: it is the only
            // subview the glass guarantees sits above the material. Adding the
            // card's own content as a plain subview could draw it underneath.
            glass.contentView = contentView
            addSubview(glass)
            glassView = glass
            // Over a white PDF page the system glass has almost nothing to
            // refract, so its rim alone is too faint. A soft shadow restores
            // the card's separation from the paper without repainting an
            // opaque background.
            glass.wantsLayer = true
            glass.layer?.shadowColor = NSColor.black.cgColor
            glass.layer?.shadowOpacity = 0.16
            glass.layer?.shadowRadius = 7
            glass.layer?.shadowOffset = CGSize(width: 0, height: -2)
            applyGlassTint()
        } else {
            // macOS 14 and 15 have no glass material, so the sticker's own
            // paper stays as the backdrop.
            addSubview(paperView)
            addSubview(contentView)
        }
    }

    /// Keeps the sticker's paper colour recognisable inside the glass without
    /// turning the card opaque again.
    private func applyGlassTint() {
        guard #available(macOS 26.0, *),
              let glass = glassView as? NSGlassEffectView
        else { return }
        glass.tintColor = preview?.palette.color.withAlphaComponent(
            CardMetrics.glassTintAlpha
        )
    }
}

// MARK: - Content

/// Everything drawn on top of the backdrop.
private final class NoteHoverCardContentView: NSView {

    var preview: NoteHoverPreview? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let preview, bounds.width > 1, bounds.height > 1 else { return }
        let layout = CardLayout(preview: preview, width: bounds.width, maxHeight: bounds.height)

        drawIcon(preview.motif, in: layout.iconRect)
        draw(layout.title, in: layout.titleRect)
        if let count = layout.count {
            draw(count, in: layout.countRect)
        }
        if let dividerY = layout.dividerY {
            drawDivider(at: dividerY)
        }
        for row in layout.rows {
            if let number = row.number, let badgeColor = row.badgeColor {
                drawBadge(number: number, color: badgeColor, in: row.badgeRect)
            }
            draw(row.text, in: row.rect)
        }
        if let footer = layout.footer {
            draw(footer, in: layout.footerRect)
        }
    }

    // MARK: - Drawing

    private func drawIcon(_ motif: NoteMotif, in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        // The card is flipped so text can be laid out top-down, but the short
        // `NSImage.draw(in:from:operation:fraction:)` overload ignores that and
        // paints the artwork upside down. Every image here has to be drawn with
        // `respectFlipped: true`. The sticker on the page can use the short
        // overload only because its overlay is not flipped.
        if let name = motif.assetName, let image = NSImage(named: NSImage.Name(name)) {
            image.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        } else if let symbol = NSImage(
            systemSymbolName: NoteStickerStyle.defaultSymbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(paletteColors: [.brown])) {
            symbol.draw(
                in: rect.insetBy(dx: 1, dy: 1),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDivider(at y: CGFloat) {
        let line = NSBezierPath()
        line.move(to: CGPoint(x: CardMetrics.padding, y: y.rounded() + 0.5))
        line.line(to: CGPoint(x: bounds.maxX - CardMetrics.padding, y: y.rounded() + 0.5))
        line.lineWidth = 1
        CardMetrics.warmInk.withAlphaComponent(0.14).setStroke()
        line.stroke()
    }

    private func drawBadge(number: Int, color: NSColor, in rect: CGRect) {
        let circle = NSBezierPath(ovalIn: rect)
        color.withAlphaComponent(0.9).setFill()
        circle.fill()
        CardMetrics.warmInk.withAlphaComponent(0.20).setStroke()
        circle.lineWidth = 0.8
        circle.stroke()

        let label = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: CardMetrics.warmInk
        ]
        let labelSize = label.size(withAttributes: attributes)
        label.draw(
            at: CGPoint(
                x: rect.midX - labelSize.width / 2,
                y: rect.midY - labelSize.height / 2
            ),
            withAttributes: attributes
        )
    }

    private func draw(_ text: NSAttributedString, in rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        text.draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
        )
    }
}

// MARK: - Painted paper backdrop

/// The pre-Liquid-Glass backdrop: a rounded white card tinted with the
/// sticker's own paper so it reads as the same note rather than a tooltip.
private final class NoteHoverCardPaperView: NSView {

    var preview: NoteHoverPreview? {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let preview, bounds.width > 1, bounds.height > 1 else { return }
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: CardMetrics.cornerRadius,
            yRadius: CardMetrics.cornerRadius
        )

        // The page behind a sticker is usually white, so a white card needs a
        // soft drop shadow to separate its edges from the paper.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = CardMetrics.warmInk.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: 2)
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        // The sticker's own paper shows through, which is what makes the card
        // read as the same note rather than a generic tooltip.
        preview.palette.color.withAlphaComponent(0.20).setFill()
        path.fill()

        CardMetrics.warmInk.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - Metrics

@MainActor
private enum CardMetrics {
    static let padding: CGFloat = 12
    static let cornerRadius: CGFloat = 12

    static let headerHeight: CGFloat = 18
    static let iconSize: CGFloat = 16
    static let iconGap: CGFloat = 7

    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let countFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let bodyFont = NSFont.systemFont(ofSize: 12)
    static let footerFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    static let bodyLineSpacing: CGFloat = 1.5
    static let badgeSize: CGFloat = 15
    static let badgeGap: CGFloat = 7
    static let entrySpacing: CGFloat = 8
    /// A single very long note is previewed, not read: it is clipped to this
    /// height and the click still opens the whole body.
    static let maximumEntryHeight: CGFloat = 92

    static let footerSpacing: CGFloat = 6
    static let footerHeight: CGFloat = 14

    /// A bare hint of the sticker's paper. A stronger tint turns system glass
    /// into a flat yellow panel on a white page; the numbered badges already
    /// carry each note's own colour.
    static let glassTintAlpha: CGFloat = 0.10

    static let ink = NSColor(srgbRed: 0.25, green: 0.20, blue: 0.17, alpha: 1)
    static let warmInk = NSColor(srgbRed: 0.44, green: 0.31, blue: 0.24, alpha: 1)
}

// MARK: - Layout

/// One measuring pass used by both `size(for:width:maxHeight:)` and `draw`.
///
/// Keeping them together is what stops a card from being placed at one size and
/// drawn at another, which would clip the last line of a note.
@MainActor
private struct CardLayout {
    struct Row {
        let text: NSAttributedString
        let rect: CGRect
        let badgeRect: CGRect
        let number: Int?
        let badgeColor: NSColor?
    }

    let size: CGSize
    let iconRect: CGRect
    let title: NSAttributedString
    let titleRect: CGRect
    let count: NSAttributedString?
    let countRect: CGRect
    let dividerY: CGFloat?
    let rows: [Row]
    let footer: NSAttributedString?
    let footerRect: CGRect

    init(preview: NoteHoverPreview, width: CGFloat, maxHeight: CGFloat) {
        let width = max(width, NoteHoverCardView.minimumWidth)
        let maxHeight = max(maxHeight, 1)
        let contentWidth = max(width - CardMetrics.padding * 2, 24)

        let count = preview.countTitle.map {
            CardText.attributed(
                $0,
                font: CardMetrics.countFont,
                color: CardMetrics.warmInk.withAlphaComponent(0.62)
            )
        }
        let countWidth = count.map { min(ceil($0.size().width), contentWidth * 0.4) } ?? 0

        let title = CardText.attributed(
            preview.title,
            font: CardMetrics.titleFont,
            color: CardMetrics.warmInk
        )
        let titleX = CardMetrics.padding + CardMetrics.iconSize + CardMetrics.iconGap
        let titleWidth = max(
            contentWidth - CardMetrics.iconSize - CardMetrics.iconGap
                - (countWidth > 0 ? countWidth + 8 : 0),
            24
        )

        let showsNumbers = preview.entries.count > 1
        let textX = CardMetrics.padding + (showsNumbers ? CardMetrics.badgeSize + CardMetrics.badgeGap : 0)
        let textWidth = max(contentWidth - (showsNumbers ? CardMetrics.badgeSize + CardMetrics.badgeGap : 0), 24)

        let texts = preview.entries.map { entry in
            CardText.attributed(
                entry.isBlank ? "Empty note" : entry.contents,
                font: CardMetrics.bodyFont,
                color: entry.isBlank
                    ? CardMetrics.warmInk.withAlphaComponent(0.55)
                    : CardMetrics.ink,
                lineSpacing: CardMetrics.bodyLineSpacing
            )
        }
        let heights = texts.map {
            min(CardText.height($0, width: textWidth), CardMetrics.maximumEntryHeight)
        }

        let headerBottom = CardMetrics.padding + CardMetrics.headerHeight
        let dividerY: CGFloat? = showsNumbers ? headerBottom + 7 : nil
        let bodyTop = (dividerY.map { $0 + 9 }) ?? (headerBottom + 9)

        let availableBody = max(maxHeight - bodyTop - CardMetrics.padding, 0)
        let totalNeeded = heights.reduce(0, +)
            + CGFloat(max(0, heights.count - 1)) * CardMetrics.entrySpacing

        var visible = heights.count
        var showsFooter = false
        if totalNeeded > availableBody {
            let footerReserve = CardMetrics.footerHeight + CardMetrics.footerSpacing
            visible = NoteHoverCardLayout.visibleEntryCount(
                entryHeights: heights,
                separatorHeight: CardMetrics.entrySpacing,
                availableHeight: max(availableBody - footerReserve, 0)
            )
            // A thread always previews at least its first note, even when that
            // note alone is taller than the card's remaining room.
            visible = max(visible, min(1, heights.count))
            showsFooter = visible < heights.count
        }

        let entryRoom = max(
            availableBody - (showsFooter ? CardMetrics.footerHeight + CardMetrics.footerSpacing : 0),
            0
        )

        var rows: [Row] = []
        var y = bodyTop
        for index in 0..<visible {
            var height = heights[index]
            if index == visible - 1 {
                height = min(height, max(entryRoom - (y - bodyTop), 0))
            }
            guard height > 0.5 else { break }
            rows.append(
                Row(
                    text: texts[index],
                    rect: CGRect(x: textX, y: y, width: textWidth, height: height),
                    badgeRect: CGRect(
                        x: CardMetrics.padding,
                        y: y + 1,
                        width: CardMetrics.badgeSize,
                        height: CardMetrics.badgeSize
                    ),
                    number: showsNumbers ? index + 1 : nil,
                    badgeColor: showsNumbers ? preview.entries[index].palette.color : nil
                )
            )
            y += height + CardMetrics.entrySpacing
        }

        let contentBottom = rows.isEmpty ? bodyTop : y - CardMetrics.entrySpacing
        let hidden = heights.count - rows.count
        let footer: NSAttributedString?
        let footerRect: CGRect
        if showsFooter, hidden > 0 {
            footer = CardText.attributed(
                hidden == 1 ? "+1 more note" : "+\(hidden) more notes",
                font: CardMetrics.footerFont,
                color: CardMetrics.warmInk.withAlphaComponent(0.62)
            )
            footerRect = CGRect(
                x: textX,
                y: contentBottom + CardMetrics.footerSpacing,
                width: textWidth,
                height: CardMetrics.footerHeight
            )
        } else {
            footer = nil
            footerRect = .zero
        }

        let bottom = footer == nil ? contentBottom : footerRect.maxY

        self.size = CGSize(width: width, height: min(bottom + CardMetrics.padding, maxHeight))
        self.iconRect = CGRect(
            x: CardMetrics.padding,
            y: CardMetrics.padding + (CardMetrics.headerHeight - CardMetrics.iconSize) / 2,
            width: CardMetrics.iconSize,
            height: CardMetrics.iconSize
        )
        self.title = title
        self.titleRect = CGRect(
            x: titleX,
            y: CardMetrics.padding,
            width: titleWidth,
            height: CardMetrics.headerHeight
        )
        self.count = count
        self.countRect = CGRect(
            x: CardMetrics.padding + contentWidth - countWidth,
            y: CardMetrics.padding + 2,
            width: countWidth,
            height: CardMetrics.headerHeight - 4
        )
        self.dividerY = dividerY
        self.rows = rows
        self.footer = footer
        self.footerRect = footerRect
    }
}

// MARK: - Text

@MainActor
private enum CardText {
    static func attributed(
        _ string: String,
        font: NSFont,
        color: NSColor,
        lineSpacing: CGFloat = 0
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        // Word wrapping, not tail truncation: a truncating paragraph style makes
        // `boundingRect` report a single line, so a long note would be measured
        // as one row and then clipped instead of wrapping. The visible end of an
        // over-long body is handled by `.truncatesLastVisibleLine` when drawing.
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    static func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let rect = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        guard rect.height.isFinite, rect.height > 0 else { return 0 }
        return ceil(rect.height)
    }
}
