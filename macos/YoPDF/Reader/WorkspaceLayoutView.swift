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
            .animation(.easeInOut(duration: 0.15), value: direction)
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

    @State private var isHovering: Bool = false

    public init(
        paneID: PaneID,
        title: String,
        pageIndicator: String,
        isPaneActive: Bool,
        canClose: Bool,
        onActivate: @escaping () -> Void,
        onClose: @escaping () -> Void,
        dragPayload: PaneDragPayload
    ) {
        self.paneID = paneID
        self.title = title
        self.pageIndicator = pageIndicator
        self.isPaneActive = isPaneActive
        self.canClose = canClose
        self.onActivate = onActivate
        self.onClose = onClose
        self.dragPayload = dragPayload
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isPaneActive ? Color.accentColor : Color.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
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
        .onDrag {
            dragPayload.asItemProvider()
        }
    }
}

/// Drop delegate for a visual pane handling drag-over direction detection and drop execution.
public struct PaneDropDelegate: DropDelegate {
    public let targetPaneID: PaneID
    public let containerSize: CGSize
    public let validateDrop: (LayoutInsertionDirection) -> (isValid: Bool, feedback: String)
    public let onHoverChanged: (PaneDropHoverState?) -> Void
    public let onPerformDrop: (DropPayload, LayoutInsertionDirection) -> Bool

    public init(
        targetPaneID: PaneID,
        containerSize: CGSize,
        validateDrop: @escaping (LayoutInsertionDirection) -> (isValid: Bool, feedback: String),
        onHoverChanged: @escaping (PaneDropHoverState?) -> Void,
        onPerformDrop: @escaping (DropPayload, LayoutInsertionDirection) -> Bool
    ) {
        self.targetPaneID = targetPaneID
        self.containerSize = containerSize
        self.validateDrop = validateDrop
        self.onHoverChanged = onHoverChanged
        self.onPerformDrop = onPerformDrop
    }

    public func dropEntered(info: DropInfo) {
        updateHover(info: info)
    }

    public func dropUpdated(info: DropInfo) -> DropProposal? {
        let direction = LayoutInsertionDirection.direction(for: info.location, in: containerSize)
        let check = validateDrop(direction)
        onHoverChanged(PaneDropHoverState(direction: direction, isValid: check.isValid, feedbackMessage: check.feedback))
        return DropProposal(operation: check.isValid ? .move : .forbidden)
    }

    public func dropExited(info: DropInfo) {
        onHoverChanged(nil)
    }

    public func performDrop(info: DropInfo) -> Bool {
        let direction = LayoutInsertionDirection.direction(for: info.location, in: containerSize)
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
        let direction = LayoutInsertionDirection.direction(for: info.location, in: containerSize)
        let check = validateDrop(direction)
        onHoverChanged(PaneDropHoverState(direction: direction, isValid: check.isValid, feedbackMessage: check.feedback))
    }
}

/// Modifier that attaches four-direction drop detection and drop handling to a pane container.
public struct PaneDropTargetModifier: ViewModifier {
    public let targetPaneID: PaneID
    public let containerSize: CGSize
    public let validateDrop: (LayoutInsertionDirection) -> (isValid: Bool, feedback: String)
    public let onHoverChanged: (PaneDropHoverState?) -> Void
    public let onPerformDrop: (DropPayload, LayoutInsertionDirection) -> Bool

    public init(
        targetPaneID: PaneID,
        containerSize: CGSize,
        validateDrop: @escaping (LayoutInsertionDirection) -> (isValid: Bool, feedback: String),
        onHoverChanged: @escaping (PaneDropHoverState?) -> Void,
        onPerformDrop: @escaping (DropPayload, LayoutInsertionDirection) -> Bool
    ) {
        self.targetPaneID = targetPaneID
        self.containerSize = containerSize
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
                    validateDrop: validateDrop,
                    onHoverChanged: onHoverChanged,
                    onPerformDrop: onPerformDrop
                )
            )
    }
}
