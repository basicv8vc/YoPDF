//
//  PureSwiftUILayout.swift
//  spikes/LayoutEngineSpike
//
//  Spike candidate A: Pure SwiftUI Recursive Split Layout Engine.
//  Created for Task P0-B-A layout evaluation.
//

import SwiftUI
import YoPDFCore

/// A pure SwiftUI recursive layout view driven directly by `WorkspaceLayoutTree`.
/// Evaluates:
/// 1. Zero-sync impedance (pure functional mapping from `WorkspaceLayoutTree`).
/// 2. Smooth divider dragging with live ratio clamping via `LayoutPolicy`.
/// 3. Declarative Drop Zone overlays (`.allowsHitTesting(false)`).
/// 4. 3-level nested split stability without Auto Layout constraint recursion.
public struct PureSwiftUIRootLayoutView: View {
    @Binding public var layoutTree: WorkspaceLayoutTree
    public let policy: LayoutPolicy
    public let isDraggingPane: Bool
    public let onDropOnZone: ((PaneID, LayoutInsertionDirection) -> Void)?
    public let contentProvider: (PaneID) -> AnyView

    public init(
        layoutTree: Binding<WorkspaceLayoutTree>,
        policy: LayoutPolicy = .default,
        isDraggingPane: Bool = false,
        onDropOnZone: ((PaneID, LayoutInsertionDirection) -> Void)? = nil,
        contentProvider: @escaping (PaneID) -> AnyView
    ) {
        self._layoutTree = layoutTree
        self.policy = policy
        self.isDraggingPane = isDraggingPane
        self.onDropOnZone = onDropOnZone
        self.contentProvider = contentProvider
    }

    public var body: some View {
        GeometryReader { geometry in
            PureSwiftUINodeView(
                node: layoutTree.root,
                containerSize: geometry.size,
                policy: policy,
                isDraggingPane: isDraggingPane,
                onRatioChanged: { updatedRoot in
                    layoutTree = WorkspaceLayoutTree(root: updatedRoot)
                },
                onDropOnZone: onDropOnZone,
                contentProvider: contentProvider
            )
        }
    }
}

/// Recursive node renderer.
struct PureSwiftUINodeView: View {
    let node: LayoutNode
    let containerSize: CGSize
    let policy: LayoutPolicy
    let isDraggingPane: Bool
    let onRatioChanged: (LayoutNode) -> Void
    let onDropOnZone: ((PaneID, LayoutInsertionDirection) -> Void)?
    let contentProvider: (PaneID) -> AnyView

    @State private var dragStartFirstDim: CGFloat? = nil
    @State private var isDraggingDivider: Bool = false

    var body: some View {
        switch node {
        case .leaf(let paneID):
            ZStack {
                contentProvider(paneID)
                    .id(paneID)

                if isDraggingPane {
                    DropZoneOverlayView(paneID: paneID) { direction in
                        onDropOnZone?(paneID, direction)
                    }
                }
            }
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
                        PureSwiftUINodeView(
                            node: first,
                            containerSize: CGSize(width: firstDim, height: containerSize.height),
                            policy: policy,
                            isDraggingPane: isDraggingPane,
                            onRatioChanged: { newFirst in
                                onRatioChanged(.split(axis: axis, ratio: clamped, first: newFirst, second: second))
                            },
                            onDropOnZone: onDropOnZone,
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

                                    // Capture stable starting dimension at drag start to prevent cumulative drift
                                    let startDim: CGFloat
                                    if let initial = dragStartFirstDim {
                                        startDim = initial
                                    } else {
                                        startDim = firstDim
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

                        PureSwiftUINodeView(
                            node: second,
                            containerSize: CGSize(width: secondDim, height: containerSize.height),
                            policy: policy,
                            isDraggingPane: isDraggingPane,
                            onRatioChanged: { newSecond in
                                onRatioChanged(.split(axis: axis, ratio: clamped, first: first, second: newSecond))
                            },
                            onDropOnZone: onDropOnZone,
                            contentProvider: contentProvider
                        )
                        .frame(width: secondDim)
                    }

                case .vertical:
                    VStack(spacing: 0) {
                        PureSwiftUINodeView(
                            node: first,
                            containerSize: CGSize(width: containerSize.width, height: firstDim),
                            policy: policy,
                            isDraggingPane: isDraggingPane,
                            onRatioChanged: { newFirst in
                                onRatioChanged(.split(axis: axis, ratio: clamped, first: newFirst, second: second))
                            },
                            onDropOnZone: onDropOnZone,
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

                                    // Capture stable starting dimension at drag start to prevent cumulative drift
                                    let startDim: CGFloat
                                    if let initial = dragStartFirstDim {
                                        startDim = initial
                                    } else {
                                        startDim = firstDim
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

                        PureSwiftUINodeView(
                            node: second,
                            containerSize: CGSize(width: containerSize.width, height: secondDim),
                            policy: policy,
                            isDraggingPane: isDraggingPane,
                            onRatioChanged: { newSecond in
                                onRatioChanged(.split(axis: axis, ratio: clamped, first: first, second: newSecond))
                            },
                            onDropOnZone: onDropOnZone,
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

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : (isHovering ? Color.secondary.opacity(0.5) : Color.gray.opacity(0.3)))
            .frame(
                width: axis == .horizontal ? thickness : nil,
                height: axis == .vertical ? thickness : nil
            )
            .overlay {
                // Interactive hit area overlay: extends grab target without expanding layout thickness
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
                    if axis == .horizontal {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityElement()
            .accessibilityLabel(axis == .horizontal ? "Vertical split divider" : "Horizontal split divider")
            .accessibilityAddTraits(.isButton)
    }
}

/// Exploratory prototype demonstrating translucent 4-direction hover preview regions (Left, Right, Top, Bottom).
///
/// NOTE on Drop Zone Status:
/// - This overlay is an exploratory prototype demonstrating hover visual feedback only.
/// - It does NOT implement real drop delivery or transactional commit (which belongs to Stage P0-B-D).
/// - Non-interference with PDFKit text selection and annotation gestures remains UNVERIFIED until full GUI integration.
/// - In a production reader, visual-only preview layers must set `.allowsHitTesting(false)` so they do not
///   intercept pointer events; actual drop targets require explicit platform drag-and-drop session handling.
struct DropZoneOverlayView: View {
    let paneID: PaneID
    let onDrop: (LayoutInsertionDirection) -> Void

    @State private var hoveredZone: LayoutInsertionDirection?

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            ZStack {
                // Background visual indication
                if let hoveredZone {
                    dropZoneHighlight(for: hoveredZone, in: proxy.size)
                        .allowsHitTesting(false)
                        .animation(.easeInOut(duration: 0.12), value: hoveredZone)
                }

                // Interactive hot zones:
                // Left
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: w * 0.3, height: h)
                    .position(x: w * 0.15, y: h * 0.5)
                    .onHover { if $0 { hoveredZone = .left } else if hoveredZone == .left { hoveredZone = nil } }

                // Right
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: w * 0.3, height: h)
                    .position(x: w * 0.85, y: h * 0.5)
                    .onHover { if $0 { hoveredZone = .right } else if hoveredZone == .right { hoveredZone = nil } }

                // Top
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: w * 0.4, height: h * 0.3)
                    .position(x: w * 0.5, y: h * 0.15)
                    .onHover { if $0 { hoveredZone = .top } else if hoveredZone == .top { hoveredZone = nil } }

                // Bottom
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: w * 0.4, height: h * 0.3)
                    .position(x: w * 0.5, y: h * 0.85)
                    .onHover { if $0 { hoveredZone = .bottom } else if hoveredZone == .bottom { hoveredZone = nil } }
            }
        }
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private func dropZoneHighlight(for zone: LayoutInsertionDirection, in size: CGSize) -> some View {
        let highlightColor = Color.accentColor.opacity(0.25)
        let borderColor = Color.accentColor.opacity(0.8)

        switch zone {
        case .left:
            RoundedRectangle(cornerRadius: 6)
                .fill(highlightColor)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 2))
                .frame(width: size.width * 0.5, height: size.height)
                .position(x: size.width * 0.25, y: size.height * 0.5)

        case .right:
            RoundedRectangle(cornerRadius: 6)
                .fill(highlightColor)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 2))
                .frame(width: size.width * 0.5, height: size.height)
                .position(x: size.width * 0.75, y: size.height * 0.5)

        case .top:
            RoundedRectangle(cornerRadius: 6)
                .fill(highlightColor)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 2))
                .frame(width: size.width, height: size.height * 0.5)
                .position(x: size.width * 0.5, y: size.height * 0.25)

        case .bottom:
            RoundedRectangle(cornerRadius: 6)
                .fill(highlightColor)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 2))
                .frame(width: size.width, height: size.height * 0.5)
                .position(x: size.width * 0.5, y: size.height * 0.75)
        }
    }
}
