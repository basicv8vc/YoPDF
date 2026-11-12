//
//  WorkspaceLayoutView.swift
//  YoPDF
//
//  Created for Task P0-B-C: Multi-Pane UI Integration.
//  Apache-2.0 Open Source License.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import YoPDFCore

/// A pure SwiftUI recursive layout view driven directly by `WorkspaceLayoutTree`.
///
/// Features:
/// 1. Direct declarative mapping from `WorkspaceLayoutTree` to recursive binary splits.
/// 2. Smooth divider dragging with live ratio clamping via `LayoutPolicy`.
/// 3. Zero layout drift by capturing drag-start dimensions.
/// 4. Preserves stable child view identities across split mutations and resizes.
public struct WorkspaceRootLayoutView<Content: View>: View {
    @Binding public var layoutTree: WorkspaceLayoutTree
    public let policy: LayoutPolicy
    public let onRatioChanged: ((WorkspaceLayoutTree) -> Void)?
    @ViewBuilder public let contentProvider: (PaneID) -> Content

    public init(
        layoutTree: Binding<WorkspaceLayoutTree>,
        policy: LayoutPolicy = .default,
        onRatioChanged: ((WorkspaceLayoutTree) -> Void)? = nil,
        @ViewBuilder contentProvider: @escaping (PaneID) -> Content
    ) {
        self._layoutTree = layoutTree
        self.policy = policy
        self.onRatioChanged = onRatioChanged
        self.contentProvider = contentProvider
    }

    public var body: some View {
        GeometryReader { geometry in
            WorkspaceNodeView(
                node: layoutTree.root,
                containerSize: geometry.size,
                policy: policy,
                onRatioChanged: { updatedRoot in
                    let newTree = WorkspaceLayoutTree(root: updatedRoot)
                    layoutTree = newTree
                    onRatioChanged?(newTree)
                },
                contentProvider: contentProvider
            )
        }
    }
}

/// Recursive node renderer supporting leaves and binary splits.
struct WorkspaceNodeView<Content: View>: View {
    let node: LayoutNode
    let containerSize: CGSize
    let policy: LayoutPolicy
    let onRatioChanged: (LayoutNode) -> Void
    @ViewBuilder let contentProvider: (PaneID) -> Content

    @State private var dragStartFirstDim: CGFloat? = nil
    @State private var isDraggingDivider: Bool = false

    var body: some View {
        switch node {
        case .leaf(let paneID):
            contentProvider(paneID)
                .id(paneID)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Visual Pane \(paneID.description)")

        case let .split(axis, ratio, first, second):
            let availableDim = (axis == .horizontal ? containerSize.width : containerSize.height) - policy.dividerThickness
            let effectiveAvailable = max(0, availableDim)
            let clamped = LayoutNode.clampedRatio(
                ratio,
                axis: axis,
                first: first,
                second: second,
                in: (axis == .horizontal ? containerSize.width : containerSize.height),
                policy: policy
            )

            let firstDim = effectiveAvailable * CGFloat(clamped)
            let secondDim = effectiveAvailable - firstDim

            Group {
                switch axis {
                case .horizontal:
                    HStack(spacing: 0) {
                        WorkspaceNodeView(
                            node: first,
                            containerSize: CGSize(width: firstDim, height: containerSize.height),
                            policy: policy,
                            onRatioChanged: { newFirst in
                                onRatioChanged(.split(axis: axis, ratio: clamped, first: newFirst, second: second))
                            },
                            contentProvider: contentProvider
                        )
                        .frame(width: firstDim)

                        DividerView(
                            axis: .horizontal,
                            thickness: policy.dividerThickness,
                            isDragging: isDraggingDivider
                        )
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    isDraggingDivider = true
                                    let effective = max(0, availableDim)
                                    guard effective > 0 else { return }

                                    let startDim = dragStartFirstDim ?? firstDim
                                    if dragStartFirstDim == nil {
                                        dragStartFirstDim = firstDim
                                    }

                                    let delta = value.translation.width
                                    let proposedFirstDim = startDim + delta
                                    let proposedRatio = Double(proposedFirstDim / effective)
                                    let clampedNewRatio = LayoutNode.clampedRatio(
                                        proposedRatio,
                                        axis: .horizontal,
                                        first: first,
                                        second: second,
                                        in: containerSize.width,
                                        policy: policy
                                    )
                                    onRatioChanged(.split(axis: axis, ratio: clampedNewRatio, first: first, second: second))
                                }
                                .onEnded { _ in
                                    isDraggingDivider = false
                                    dragStartFirstDim = nil
                                }
                        )

                        WorkspaceNodeView(
                            node: second,
                            containerSize: CGSize(width: secondDim, height: containerSize.height),
                            policy: policy,
                            onRatioChanged: { newSecond in
                                onRatioChanged(.split(axis: axis, ratio: clamped, first: first, second: newSecond))
                            },
                            contentProvider: contentProvider
                        )
                        .frame(width: secondDim)
                    }

                case .vertical:
                    VStack(spacing: 0) {
                        WorkspaceNodeView(
                            node: first,
                            containerSize: CGSize(width: containerSize.width, height: firstDim),
                            policy: policy,
                            onRatioChanged: { newFirst in
                                onRatioChanged(.split(axis: axis, ratio: clamped, first: newFirst, second: second))
                            },
                            contentProvider: contentProvider
                        )
                        .frame(height: firstDim)

                        DividerView(
                            axis: .vertical,
                            thickness: policy.dividerThickness,
                            isDragging: isDraggingDivider
                        )
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    isDraggingDivider = true
                                    let effective = max(0, availableDim)
                                    guard effective > 0 else { return }

                                    let startDim = dragStartFirstDim ?? firstDim
                                    if dragStartFirstDim == nil {
                                        dragStartFirstDim = firstDim
                                    }

                                    let delta = value.translation.height
                                    let proposedFirstDim = startDim + delta
                                    let proposedRatio = Double(proposedFirstDim / effective)
                                    let clampedNewRatio = LayoutNode.clampedRatio(
                                        proposedRatio,
                                        axis: .vertical,
                                        first: first,
                                        second: second,
                                        in: containerSize.height,
                                        policy: policy
                                    )
                                    onRatioChanged(.split(axis: axis, ratio: clampedNewRatio, first: first, second: second))
                                }
                                .onEnded { _ in
                                    isDraggingDivider = false
                                    dragStartFirstDim = nil
                                }
                        )

                        WorkspaceNodeView(
                            node: second,
                            containerSize: CGSize(width: containerSize.width, height: secondDim),
                            policy: policy,
                            onRatioChanged: { newSecond in
                                onRatioChanged(.split(axis: axis, ratio: clamped, first: first, second: newSecond))
                            },
                            contentProvider: contentProvider
                        )
                        .frame(height: secondDim)
                    }
                }
            }
        }
    }
}

/// Visual divider with cursor feedback and hit-testing padding that does not expand layout thickness.
struct DividerView: View {
    let axis: SplitAxis
    let thickness: CGFloat
    let isDragging: Bool

    @State private var isHovering: Bool = false
    @State private var didPushCursor: Bool = false

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : (isHovering ? Color.secondary.opacity(0.5) : Color.gray.opacity(0.3)))
            .frame(
                width: axis == .horizontal ? thickness : nil,
                height: axis == .vertical ? thickness : nil
            )
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(
                        width: axis == .horizontal ? max(8, thickness) : nil,
                        height: axis == .vertical ? max(8, thickness) : nil
                    )
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    if !didPushCursor {
                        if axis == .horizontal {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.resizeUpDown.push()
                        }
                        didPushCursor = true
                    }
                } else {
                    if didPushCursor {
                        NSCursor.pop()
                        didPushCursor = false
                    }
                }
            }
            .onDisappear {
                if didPushCursor {
                    NSCursor.pop()
                    didPushCursor = false
                }
            }
            .accessibilityElement()
            .accessibilityLabel(axis == .horizontal ? "Vertical split divider" : "Horizontal split divider")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Pane Drag & Drop Views and Modifiers

/// A clear, semi-transparent preview overlay showing the target split region and validation feedback.
public struct PaneDropPreviewOverlay: View {
    public let direction: LayoutInsertionDirection
    public let isValid: Bool
    public let feedbackMessage: String

    public init(direction: LayoutInsertionDirection, isValid: Bool = true, feedbackMessage: String = "") {
        self.direction = direction
        self.isValid = isValid
        self.feedbackMessage = feedbackMessage
    }

    public var body: some View {
        GeometryReader { geometry in
            let frame = previewRect(in: geometry.size)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isValid ? Color.accentColor.opacity(0.24) : Color.red.opacity(0.18))

                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isValid ? Color.accentColor : Color.red.opacity(0.8),
                        style: StrokeStyle(lineWidth: 2, dash: isValid ? [] : [6, 4])
                    )

                VStack(spacing: 6) {
                    Image(systemName: isValid ? directionSymbolName : "exclamationmark.triangle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isValid ? Color.accentColor : Color.red)

                    Text(isValid ? "Split \(direction.rawValue.capitalized)" : feedbackMessage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isValid ? Color.primary : Color.red)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .animation(.easeOut(duration: 0.14), value: direction)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Split \(direction.rawValue) drop preview")
            .accessibilityIdentifier("pane-drop-preview-\(direction.rawValue)")
        }
    }

    private func previewRect(in size: CGSize) -> CGRect {
        switch direction {
        case .left:
            return CGRect(x: 0, y: 0, width: size.width * 0.5, height: size.height)
        case .right:
            return CGRect(x: size.width * 0.5, y: 0, width: size.width * 0.5, height: size.height)
        case .top:
            return CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.5)
        case .bottom:
            return CGRect(x: 0, y: size.height * 0.5, width: size.width, height: size.height * 0.5)
        }
    }

    private var directionSymbolName: String {
        switch direction.axis {
        case .horizontal:
            return "rectangle.split.2x1"
        case .vertical:
            return "rectangle.split.1x2"
        }
    }
}

/// A dedicated header bar for each PDF pane containing title, page info, active indicator, close button, and a native drag handle.
public struct PaneHeaderView: View {
    public let paneID: PaneID
    public let title: String
    public let pageIndicator: String
    public let isPaneActive: Bool
    public let canClose: Bool
    public let onActivate: () -> Void
    public let onClose: () -> Void
    public let dragPayload: PaneDragPayload
    public var onDragStarted: (() -> Void)? = nil
    /// Called from the native `NSDraggingSource` drag-ended lifecycle callback
    /// for every session end: successful drop, rejected drop, Esc
    /// cancellation, or release outside every drop target.
    public var onDragEnded: (() -> Void)? = nil

    @State private var isHovering: Bool = false

    public init(
        paneID: PaneID,
        title: String,
        pageIndicator: String,
        isPaneActive: Bool,
        canClose: Bool,
        onActivate: @escaping () -> Void,
        onClose: @escaping () -> Void,
        dragPayload: PaneDragPayload,
        onDragStarted: (() -> Void)? = nil,
        onDragEnded: (() -> Void)? = nil
    ) {
        self.paneID = paneID
        self.title = title
        self.pageIndicator = pageIndicator
        self.isPaneActive = isPaneActive
        self.canClose = canClose
        self.onActivate = onActivate
        self.onClose = onClose
        self.dragPayload = dragPayload
        self.onDragStarted = onDragStarted
        self.onDragEnded = onDragEnded
    }

    public var body: some View {
        HStack(spacing: 6) {
            // Subtle drag handle that becomes prominent on hover; drag originates strictly here
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isPaneActive ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovering ? Color.secondary.opacity(0.14) : Color.clear)
                )
                .opacity(isHovering ? 1.0 : 0.45)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
                .contentShape(Rectangle())
                .overlay {
                    PaneDragSource(
                        payload: dragPayload,
                        previewTitle: title,
                        onDragStarted: { onDragStarted?() },
                        onDragEnded: { onDragEnded?() },
                        onClick: { onActivate() }
                    )
                }
                .help("Drag to move or split pane")
                .accessibilityLabel("Drag handle for pane \(title)")
                .accessibilityIdentifier("pane-drag-handle-\(paneID.description)")

            Text(title)
                .font(.system(size: 11, weight: isPaneActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isPaneActive ? Color.primary : Color.secondary)
                .accessibilityIdentifier("pane-title-\(paneID.description)")

            if !pageIndicator.isEmpty {
                Text(pageIndicator)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close pane")
                .accessibilityLabel("Close \(title) pane")
                .accessibilityIdentifier("pane-close-\(paneID.description)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            isPaneActive
                ? Color.accentColor.opacity(0.12)
                : (isHovering ? Color.secondary.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            onActivate()
        }
    }
}

/// Drop delegate for a visual pane handling drag-over direction detection with hysteresis and drop execution.
public struct PaneDropDelegate: DropDelegate {
    public let targetPaneID: PaneID
    public let containerSize: CGSize
    public let currentHoverDirection: LayoutInsertionDirection?
    public let validateDrop: (LayoutInsertionDirection) -> (isValid: Bool, feedback: String)
    public let onHoverChanged: (PaneDropHoverState?) -> Void
    public let onPerformDrop: (DropPayload, LayoutInsertionDirection) -> Bool

    public init(
        targetPaneID: PaneID,
        containerSize: CGSize,
        currentHoverDirection: LayoutInsertionDirection? = nil,
        validateDrop: @escaping (LayoutInsertionDirection) -> (isValid: Bool, feedback: String),
        onHoverChanged: @escaping (PaneDropHoverState?) -> Void,
        onPerformDrop: @escaping (DropPayload, LayoutInsertionDirection) -> Bool
    ) {
        self.targetPaneID = targetPaneID
        self.containerSize = containerSize
        self.currentHoverDirection = currentHoverDirection
        self.validateDrop = validateDrop
        self.onHoverChanged = onHoverChanged
        self.onPerformDrop = onPerformDrop
    }

    public static func dropOperation(
        isPaneOrTab: Bool,
        isExternalFile: Bool,
        isValidDestination: Bool
    ) -> DropOperation {
        guard isValidDestination else { return .forbidden }
        if isPaneOrTab {
            return .move
        } else if isExternalFile {
            return .copy
        } else {
            return .forbidden
        }
    }

    public func dropEntered(info: DropInfo) {
        updateHover(info: info)
    }

    public func dropUpdated(info: DropInfo) -> DropProposal? {
        let direction = LayoutInsertionDirection.direction(
            for: info.location,
            in: containerSize,
            previousDirection: currentHoverDirection,
            hysteresis: 0.05
        )
        let check = validateDrop(direction)
        onHoverChanged(PaneDropHoverState(direction: direction, isValid: check.isValid, feedbackMessage: check.feedback))

        let isPaneOrTab = info.hasItemsConforming(to: [UTType.yoPDFPaneDrag])
        let isExternalFile = info.hasItemsConforming(to: [UTType.fileURL, UTType.pdf])
        let op = Self.dropOperation(
            isPaneOrTab: isPaneOrTab,
            isExternalFile: isExternalFile,
            isValidDestination: check.isValid
        )
        return DropProposal(operation: op)
    }

    public func dropExited(info: DropInfo) {
        onHoverChanged(nil)
    }

    public func performDrop(info: DropInfo) -> Bool {
        let direction = LayoutInsertionDirection.direction(
            for: info.location,
            in: containerSize,
            previousDirection: currentHoverDirection,
            hysteresis: 0.05
        )
        let check = validateDrop(direction)
        onHoverChanged(nil)
        guard check.isValid else { return false }

        if info.hasItemsConforming(to: [UTType.yoPDFPaneDrag]) {
            guard let provider = info.itemProviders(for: [UTType.yoPDFPaneDrag]).first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.yoPDFPaneDrag.identifier) { data, _ in
                guard let data, let payload = try? JSONDecoder().decode(PaneDragPayload.self, from: data) else { return }
                Task { @MainActor in
                    _ = onPerformDrop(.pane(payload), direction)
                }
            }
            return true
        } else if info.hasItemsConforming(to: [UTType.fileURL, UTType.pdf]) {
            guard let provider = info.itemProviders(for: [UTType.fileURL, UTType.pdf]).first else { return false }
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in
                        _ = onPerformDrop(.fileURL(url), direction)
                    }
                }
                return true
            } else {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let candidate: URL?
                    if let url = item as? URL {
                        candidate = url
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        candidate = url
                    } else {
                        candidate = nil
                    }
                    guard let finalURL = candidate, finalURL.isFileURL else { return }
                    Task { @MainActor in
                        _ = onPerformDrop(.fileURL(finalURL), direction)
                    }
                }
                return true
            }
        }
        return false
    }

    private func updateHover(info: DropInfo) {
        let direction = LayoutInsertionDirection.direction(
            for: info.location,
            in: containerSize,
            previousDirection: currentHoverDirection,
            hysteresis: 0.05
        )
        let check = validateDrop(direction)
        onHoverChanged(PaneDropHoverState(direction: direction, isValid: check.isValid, feedbackMessage: check.feedback))
    }
}

/// Modifier that attaches four-direction drop detection and drop handling to a pane container.
public struct PaneDropTargetModifier: ViewModifier {
    public let targetPaneID: PaneID
    public let containerSize: CGSize
    public let currentHoverDirection: LayoutInsertionDirection?
    public let validateDrop: (LayoutInsertionDirection) -> (isValid: Bool, feedback: String)
    public let onHoverChanged: (PaneDropHoverState?) -> Void
    public let onPerformDrop: (DropPayload, LayoutInsertionDirection) -> Bool

    public init(
        targetPaneID: PaneID,
        containerSize: CGSize,
        currentHoverDirection: LayoutInsertionDirection? = nil,
        validateDrop: @escaping (LayoutInsertionDirection) -> (isValid: Bool, feedback: String),
        onHoverChanged: @escaping (PaneDropHoverState?) -> Void,
        onPerformDrop: @escaping (DropPayload, LayoutInsertionDirection) -> Bool
    ) {
        self.targetPaneID = targetPaneID
        self.containerSize = containerSize
        self.currentHoverDirection = currentHoverDirection
        self.validateDrop = validateDrop
        self.onHoverChanged = onHoverChanged
        self.onPerformDrop = onPerformDrop
    }

    public func body(content: Content) -> some View {
        content
            .onDrop(
                of: [UTType.yoPDFPaneDrag, UTType.fileURL, UTType.pdf],
                delegate: PaneDropDelegate(
                    targetPaneID: targetPaneID,
                    containerSize: containerSize,
                    currentHoverDirection: currentHoverDirection,
                    validateDrop: validateDrop,
                    onHoverChanged: onHoverChanged,
                    onPerformDrop: onPerformDrop
                )
            )
    }
}

// MARK: - Native Drag Source

/// AppKit drag source for pane and tab payloads.
///
/// SwiftUI's `onDrag` never reports when a drag session ends, so a drag that
/// was cancelled (Esc), rejected, or released outside every drop target would
/// leave the source pane dimmed and hover overlays stuck on screen. This view
/// starts the session natively and restores that state from
/// `draggingSession(_:endedAt:operation:)`, the callback AppKit guarantees for
/// every session end. No polling or custom drag tracking is involved.
@MainActor
final class PaneDragSourceView: NSView, NSDraggingSource {

    /// Payload serialized when a drag actually starts.
    var makePayload: () -> PaneDragPayload = {
        PaneDragPayload(kind: .pane, sourceTabID: UUID(), sourcePaneID: nil)
    }
    /// Title shown on the floating drag preview pill.
    var previewTitle: () -> String = { "" }
    var onDragStarted: () -> Void = {}
    var onDragEnded: () -> Void = {}
    /// Fired for a plain left click that never became a drag. When `nil` and
    /// `forwardsUnclaimedClicks` is set, such a click is forwarded to the
    /// SwiftUI content underneath instead (tab capsules with Buttons).
    var onClick: (() -> Void)?
    var forwardsUnclaimedClicks = false

    /// Movement in points before a press turns into a drag, matching the
    /// feel of SwiftUI's `onDrag` threshold.
    private static let dragThreshold: CGFloat = 3
    private static let previewOffset = CGPoint(x: 12, y: 4)

    private var pendingMouseDown: NSEvent?
    private var didBeginSession = false
    private var isForwardingClick = false

    // MARK: Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        // While forwarding a synthetic click the content underneath must win.
        if isForwardingClick { return nil }
        // Only left presses are claimed. Right clicks and other events fall
        // through so context menus, hover, and scrolling keep working.
        if NSApp.currentEvent?.type != .leftMouseDown { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // A click in an inactive window should activate the window first,
        // matching the SwiftUI behaviour this replaces.
        false
    }

    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Mouse Tracking

    override func mouseDown(with event: NSEvent) {
        pendingMouseDown = event
        didBeginSession = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didBeginSession, let mouseDown = pendingMouseDown else { return }
        let start = convert(mouseDown.locationInWindow, from: nil)
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - start.x, current.y - start.y) >= Self.dragThreshold else { return }
        didBeginSession = true
        beginPayloadSession(with: event, dragPoint: current)
    }

    override func mouseUp(with event: NSEvent) {
        guard let mouseDown = pendingMouseDown, !didBeginSession else {
            pendingMouseDown = nil
            return
        }
        pendingMouseDown = nil
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if let onClick {
            onClick()
        } else if forwardsUnclaimedClicks {
            deliverSyntheticClick(down: mouseDown, up: event)
        }
    }

    private func beginPayloadSession(with event: NSEvent, dragPoint: NSPoint) {
        let payload = makePayload()
        let pasteboardItem = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(payload) {
            pasteboardItem.setData(
                data,
                forType: NSPasteboard.PasteboardType(UTType.yoPDFPaneDrag.identifier)
            )
        }
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = Self.previewImage(title: previewTitle())
        // The pill floats near the pointer like a SwiftUI drag preview. The
        // frame is in this view's coordinate system, as beginDraggingSession
        // requires.
        let frame = CGRect(
            x: dragPoint.x + Self.previewOffset.x,
            y: dragPoint.y - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )
        item.setDraggingFrame(frame, contents: image)
        onDragStarted()
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.draggingFormation = NSDraggingFormation.none
    }

    /// Forwards a plain click to the SwiftUI content underneath this overlay,
    /// so Buttons keep their actions without any hit-testable gap.
    private func deliverSyntheticClick(down: NSEvent, up: NSEvent) {
        guard let contentView = window?.contentView else {
            onClick?()
            return
        }
        isForwardingClick = true
        defer { isForwardingClick = false }
        // `hitTest` points are in the superview's coordinate system, which for
        // the content view is the window base coordinate space.
        guard let target = contentView.hitTest(down.locationInWindow), target !== self else {
            onClick?()
            return
        }
        target.mouseDown(with: down)
        target.mouseUp(with: up)
    }

    /// Restores visual state after any drag session end. Also invoked by
    /// `draggingSession(_:endedAt:operation:)`; exposed for model-level tests.
    func dragSessionDidEnd() {
        pendingMouseDown = nil
        didBeginSession = false
        onDragEnded()
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [] : [.move, .copy]
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // AppKit fires this for every session end: successful drop, rejected
        // drop, Esc cancellation, or release outside every target.
        dragSessionDidEnd()
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    // MARK: Preview

    private static func previewImage(title: String) -> NSImage {
        let iconSize = NSSize(width: 12, height: 12)
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let displayTitle = title.count > 28 ? String(title.prefix(28)) + "…" : title
        let titleString = NSAttributedString(
            string: displayTitle,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        )
        let spacing: CGFloat = 6
        let paddingX: CGFloat = 10
        let paddingY: CGFloat = 6
        let titleSize = titleString.size()
        let width = ceil(paddingX * 2 + iconSize.width + spacing + titleSize.width)
        let height = ceil(paddingY * 2 + max(iconSize.height, titleSize.height))
        let size = NSSize(width: max(width, 40), height: max(height, 24))

        return NSImage(size: size, flipped: false) { rect in
            let pillRect = rect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6)
            NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()

            if let icon = NSImage(
                systemSymbolName: "doc.text.fill",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])) {
                let iconRect = NSRect(
                    x: paddingX,
                    y: paddingY + (size.height - paddingY * 2 - iconSize.height) / 2,
                    width: iconSize.width,
                    height: iconSize.height
                )
                icon.draw(in: iconRect)
            }

            titleString.draw(
                at: NSPoint(
                    x: paddingX + iconSize.width + spacing,
                    y: paddingY + (size.height - paddingY * 2 - titleSize.height) / 2
                )
            )
            return true
        }
    }
}

/// SwiftUI wrapper hosting `PaneDragSourceView` over a drag handle or capsule.
struct PaneDragSource: NSViewRepresentable {
    let payload: PaneDragPayload
    let previewTitle: String
    let onDragStarted: () -> Void
    let onDragEnded: () -> Void
    var onClick: (() -> Void)? = nil
    var forwardsUnclaimedClicks = false

    func makeNSView(context: Context) -> PaneDragSourceView {
        PaneDragSourceView()
    }

    func updateNSView(_ nsView: PaneDragSourceView, context: Context) {
        nsView.makePayload = { payload }
        nsView.previewTitle = { previewTitle }
        nsView.onDragStarted = onDragStarted
        nsView.onDragEnded = onDragEnded
        nsView.onClick = onClick
        nsView.forwardsUnclaimedClicks = forwardsUnclaimedClicks
    }
}
