//
//  WorkspaceLayoutView.swift
//  YoPDF
//
//  Created for Task P0-B-C: Multi-Pane UI Integration.
//  Apache-2.0 Open Source License.
//

import AppKit
import SwiftUI
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
