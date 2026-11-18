//
//  MarkdownPaneView.swift
//  YoPDF
//
//  Created for Task P0-C-C: Heterogeneous Markdown Pane Integration.
//  Apache-2.0 Open Source License.
//

import SwiftUI
import YoPDFCore

/// Visual pane container hosting a `MarkdownEditorView` backed by a shared
/// `MarkdownResourceSession`, complete with split-pane header, drag-and-drop
/// preview overlay, focus-driven pane activation, and citation link routing.
struct MarkdownPaneView: View {
    let paneID: PaneID
    let tabID: UUID
    let paneCount: Int
    let isPaneActive: Bool
    let isDraggingThisPane: Bool
    @ObservedObject var paneModel: MarkdownPaneModel
    @ObservedObject var resourceSession: MarkdownResourceSession
    let hoverState: PaneDropHoverState?
    let onActivate: () -> Void
    let onClose: () -> Void
    let onDragStarted: () -> Void
    let onDragEnded: () -> Void
    let onOpenLink: (String) -> Void
    let paneDropSink: PaneDropSink

    private var paneTitle: String {
        resourceSession.fileURL?.lastPathComponent ?? (resourceSession.title.isEmpty ? "Notes.md" : resourceSession.title)
    }

    private var statusBadge: String {
        if resourceSession.isReadOnlyAtOpen {
            return "Read-Only"
        }
        return resourceSession.hasUnsavedChanges ? "Edited" : "MD"
    }

    var body: some View {
        VStack(spacing: 0) {
            if paneCount > 1 {
                PaneHeaderView(
                    paneID: paneID,
                    title: paneTitle,
                    pageIndicator: statusBadge,
                    isPaneActive: isPaneActive,
                    canClose: paneCount > 1,
                    onActivate: onActivate,
                    onClose: onClose,
                    dragPayload: PaneDragPayload(kind: .pane, sourceTabID: tabID, sourcePaneID: paneID),
                    onDragStarted: onDragStarted,
                    onDragEnded: onDragEnded
                )
            }

            ZStack {
                MarkdownEditorView(
                    text: Binding(
                        get: { resourceSession.content },
                        set: { newValue in
                            resourceSession.updateContent(newValue, from: paneID)
                        }
                    ),
                    selection: Binding(
                        get: { paneModel.selectionRange },
                        set: { paneModel.selectionRange = $0 }
                    ),
                    configuration: effectiveConfiguration,
                    controller: paneModel.editorController,
                    onFocusChange: { isFocused in
                        if isFocused {
                            onActivate()
                        }
                    },
                    onOpenLink: onOpenLink,
                    paneDropSink: paneDropSink
                )
                .id(resourceSession.loadGeneration)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if paneCount > 1 {
                    Rectangle()
                        .strokeBorder(isPaneActive ? Color.accentColor.opacity(0.65) : Color.clear, lineWidth: 2)
                        .allowsHitTesting(false)
                }

                if let hoverState {
                    PaneDropPreviewOverlay(
                        zone: hoverState.zone,
                        isValid: hoverState.isValid,
                        feedbackMessage: hoverState.feedbackMessage
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .opacity(isDraggingThisPane ? 0.45 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isDraggingThisPane)
        .contentShape(Rectangle())
        .onTapGesture {
            onActivate()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown Pane \(paneTitle)\(isPaneActive ? ", active" : "")")
    }

    private var effectiveConfiguration: MarkdownEditorConfiguration {
        var config = paneModel.configuration
        if resourceSession.isReadOnlyAtOpen {
            config.isEditable = false
        }
        return config
    }
}
