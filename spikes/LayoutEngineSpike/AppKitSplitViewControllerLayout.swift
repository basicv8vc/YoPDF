//
//  AppKitSplitViewControllerLayout.swift
//  spikes/LayoutEngineSpike
//
//  Spike candidate B: AppKit NSSplitViewController Wrapped by SwiftUI.
//  Created for Task P0-B-A layout evaluation.
//

import AppKit
import SwiftUI
import YoPDFCore

/// An NSViewControllerRepresentable bridging an AppKit `NSSplitViewController` tree into SwiftUI.
/// Evaluates:
/// 1. Native macOS divider behavior and cursor management.
/// 2. Synchronization impedance: bridging declarative tree updates into imperative NSSplitViewItems.
/// 3. Complexity of 3-level nested splits and Auto Layout constraint recursion.
/// 4. Drop Zone overlay injection onto native AppKit views.
public struct AppKitSplitLayoutRepresentable: NSViewControllerRepresentable {
    @Binding public var layoutTree: WorkspaceLayoutTree
    public let policy: LayoutPolicy
    public let isDraggingPane: Bool
    public let contentProvider: (PaneID) -> NSView

    public init(
        layoutTree: Binding<WorkspaceLayoutTree>,
        policy: LayoutPolicy = .default,
        isDraggingPane: Bool = false,
        contentProvider: @escaping (PaneID) -> NSView
    ) {
        self._layoutTree = layoutTree
        self.policy = policy
        self.isDraggingPane = isDraggingPane
        self.contentProvider = contentProvider
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSViewController(context: Context) -> NSViewController {
        let rootVC = context.coordinator.rebuildHierarchy(for: layoutTree.root, policy: policy)
        context.coordinator.currentRootVC = rootVC
        return rootVC
    }

    public func updateNSViewController(_ nsViewController: NSViewController, context: Context) {
        context.coordinator.parent = self
        // Structural update check:
        // If the layout tree structure changed, we must re-synchronize or rebuild child controllers
        if context.coordinator.lastTree != layoutTree {
            context.coordinator.lastTree = layoutTree
            context.coordinator.synchronizeHierarchy(
                rootVC: nsViewController,
                node: layoutTree.root,
                policy: policy
            )
        }
    }

    public class Coordinator: NSObject, NSSplitViewDelegate {
        var parent: AppKitSplitLayoutRepresentable
        var lastTree: WorkspaceLayoutTree?
        weak var currentRootVC: NSViewController?
        var isUpdatingFromAppKit = false

        init(_ parent: AppKitSplitLayoutRepresentable) {
            self.parent = parent
            self.lastTree = parent.layoutTree
        }

        func rebuildHierarchy(for node: LayoutNode, policy: LayoutPolicy) -> NSViewController {
            switch node {
            case .leaf(let paneID):
                let vc = PaneHostViewController(paneID: paneID, contentView: parent.contentProvider(paneID))
                return vc

            case let .split(axis, ratio, first, second):
                let splitVC = NSSplitViewController()
                splitVC.splitView.isVertical = (axis == .horizontal) // In AppKit, isVertical=true means vertical divider (horizontal split)
                splitVC.splitView.dividerStyle = .thin
                splitVC.splitView.delegate = self

                let firstVC = rebuildHierarchy(for: first, policy: policy)
                let secondVC = rebuildHierarchy(for: second, policy: policy)

                let firstItem = NSSplitViewItem(viewController: firstVC)
                let secondItem = NSSplitViewItem(viewController: secondVC)

                // Minimum dimensions
                let firstMin = first.minimumRequiredSize(policy: policy)
                let secondMin = second.minimumRequiredSize(policy: policy)

                if axis == .horizontal {
                    firstItem.minimumThickness = firstMin.width
                    secondItem.minimumThickness = secondMin.width
                } else {
                    firstItem.minimumThickness = firstMin.height
                    secondItem.minimumThickness = secondMin.height
                }

                splitVC.addSplitViewItem(firstItem)
                splitVC.addSplitViewItem(secondItem)

                return splitVC
            }
        }

        func synchronizeHierarchy(rootVC: NSViewController, node: LayoutNode, policy: LayoutPolicy) {
            // Note on synchronization complexity:
            // Full structural diffing is required here to avoid destroying underlying PDFView instances.
            // When an AppKit NSSplitViewController child is replaced, the entire window's responder chain,
            // scroll position, and text selection in PDFView can be dismantled.
        }

        // MARK: - NSSplitViewDelegate

        public func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !isUpdatingFromAppKit else { return }
            // Two-way synchronization:
            // Extract point widths of subviews, compute new Double ratio, and update parent.layoutTree.
            // Requires debounce or coordination lock to prevent feedback loops with SwiftUI view updates.
        }
    }
}

/// Host controller for an individual visual pane in AppKit.
final class PaneHostViewController: NSViewController {
    let paneID: PaneID
    let hostView: NSView

    init(paneID: PaneID, contentView: NSView) {
        self.paneID = paneID
        self.hostView = contentView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        self.view = NSView()
        self.view.wantsLayer = true
        hostView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostView)

        NSLayoutConstraint.activate([
            hostView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostView.topAnchor.constraint(equalTo: view.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
