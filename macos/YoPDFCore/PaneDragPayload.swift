//
//  PaneDragPayload.swift
//  YoPDFCore
//
//  Created for Task P0-B-D: Native Pane Drag & Drop.
//  Apache-2.0 Open Source License.
//

import AppKit
import Foundation
import CoreTransferable
import UniformTypeIdentifiers

public extension UTType {
    /// Uniform Type Identifier for internal Pane and Tab drag payloads.
    static let yoPDFPaneDrag = UTType(exportedAs: "com.basicv8vc.yopdf.pane-drag", conformingTo: .data)
}

/// Payload serialized during Drag & Drop operations of PDF Panes and Single-Pane Tabs.
public struct PaneDragPayload: Codable, Transferable, Sendable, Equatable {
    public enum DragKind: String, Codable, Sendable {
        case pane
        case tab
    }

    public let kind: DragKind
    public let sourceTabID: UUID
    public let sourcePaneID: PaneID?

    public init(kind: DragKind, sourceTabID: UUID, sourcePaneID: PaneID? = nil) {
        self.kind = kind
        self.sourceTabID = sourceTabID
        self.sourcePaneID = sourcePaneID
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .yoPDFPaneDrag)
    }

    public func asItemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        if let data = try? JSONEncoder().encode(self) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.yoPDFPaneDrag.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    public static func load(from itemProvider: NSItemProvider, completion: @escaping @Sendable (PaneDragPayload?) -> Void) {
        if itemProvider.hasItemConformingToTypeIdentifier(UTType.yoPDFPaneDrag.identifier) {
            itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.yoPDFPaneDrag.identifier) { data, _ in
                guard let data, let payload = try? JSONDecoder().decode(PaneDragPayload.self, from: data) else {
                    completion(nil)
                    return
                }
                completion(payload)
            }
        } else {
            completion(nil)
        }
    }
}

/// Universal payload representing a drop from either an internal pane/tab or a Finder PDF file.
public enum DropPayload: Sendable, Equatable {
    case pane(PaneDragPayload)
    case fileURL(URL)
}

/// The five drop modes supported when dragging a PDF or pane onto an existing pane:
/// occupy/replace the target pane (`center`), or split and occupy one of its four edges.
public enum PaneDropZone: String, Codable, Sendable, CaseIterable {
    case center
    case left
    case right
    case top
    case bottom

    /// The corresponding split insertion direction, or `nil` when occupying (`center`) the target pane.
    public var insertionDirection: LayoutInsertionDirection? {
        switch self {
        case .center:
            return nil
        case .left:
            return .left
        case .right:
            return .right
        case .top:
            return .top
        case .bottom:
            return .bottom
        }
    }

    /// Creates an edge-split drop zone from a `LayoutInsertionDirection`.
    public init(direction: LayoutInsertionDirection) {
        switch direction {
        case .left:
            self = .left
        case .right:
            self = .right
        case .top:
            self = .top
        case .bottom:
            self = .bottom
        }
    }

    /// Resolves the drop zone for a point inside a pane container (`top-left` origin),
    /// reserving the inner box (`[0.28, 0.72]`) for occupying the target pane and the
    /// outer bands for four-way splitting, with hysteresis across zone boundaries.
    public static func zone(
        for point: CGPoint,
        in size: CGSize,
        previousZone: PaneDropZone? = nil,
        hysteresis: CGFloat = 0.05
    ) -> PaneDropZone {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let nx = min(max(point.x / width, 0), 1)
        let ny = min(max(point.y / height, 0), 1)
        let minEdgeDistance = min(nx, 1 - nx, ny, 1 - ny)

        let centerInset: CGFloat = 0.28
        let centerThreshold = previousZone == .center
            ? max(0, centerInset - hysteresis)
            : centerInset

        if minEdgeDistance >= centerThreshold {
            return .center
        }

        let edgeDirection = LayoutInsertionDirection.direction(
            for: point,
            in: size,
            previousDirection: previousZone?.insertionDirection,
            hysteresis: hysteresis
        )
        return PaneDropZone(direction: edgeDirection)
    }
}

/// Hover state describing target drop zone and validation for drop preview.
public struct PaneDropHoverState: Equatable, Sendable {
    public let zone: PaneDropZone
    public let isValid: Bool
    public let feedbackMessage: String

    /// Convenience accessor for edge-split hover states (`nil` when `.center`).
    public var direction: LayoutInsertionDirection? {
        zone.insertionDirection
    }

    public init(zone: PaneDropZone, isValid: Bool, feedbackMessage: String = "") {
        self.zone = zone
        self.isValid = isValid
        self.feedbackMessage = feedbackMessage
    }

    public init(direction: LayoutInsertionDirection, isValid: Bool, feedbackMessage: String = "") {
        self.init(zone: PaneDropZone(direction: direction), isValid: isValid, feedbackMessage: feedbackMessage)
    }
}

/// Callbacks wiring a drop destination (AppKit or SwiftUI) into the pane
/// layout model, so the destination layer only decides *where* and *what*,
/// while the layout rules stay here.
public struct PaneDropSink: Sendable {
    public let validate: @MainActor @Sendable (DropPayload, PaneDropZone) -> (isValid: Bool, feedback: String)
    public let onHoverChanged: @MainActor @Sendable (PaneDropHoverState?) -> Void
    public let onPerformDrop: @MainActor @Sendable (DropPayload, PaneDropZone) -> Bool

    public init(
        validate: @escaping @MainActor @Sendable (DropPayload, PaneDropZone) -> (isValid: Bool, feedback: String),
        onHoverChanged: @escaping @MainActor @Sendable (PaneDropHoverState?) -> Void,
        onPerformDrop: @escaping @MainActor @Sendable (DropPayload, PaneDropZone) -> Bool
    ) {
        self.validate = validate
        self.onHoverChanged = onHoverChanged
        self.onPerformDrop = onPerformDrop
    }

    /// AppKit drag operation for a resolved payload: in-app panes move,
    /// external files copy.
    public func dropOperation(for payload: DropPayload) -> NSDragOperation {
        switch payload {
        case .pane: return [.move]
        case .fileURL: return [.copy]
        }
    }
}

/// Shared AppKit dragging-destination helper used by heterogeneous pane hosts
/// (`MarkupPDFView`, `MarkdownNSTextView`) so drop-zone direction hysteresis,
/// payload decoding, and hover cleanup live in one place.
@MainActor
public final class PaneDropSessionHandler {
    public var sink: PaneDropSink?
    private var activeZone: PaneDropZone?

    public init(sink: PaneDropSink? = nil) {
        self.sink = sink
    }

    public static var supportedPasteboardTypes: [NSPasteboard.PasteboardType] {
        [
            NSPasteboard.PasteboardType(UTType.yoPDFPaneDrag.identifier),
            NSPasteboard.PasteboardType(UTType.fileURL.identifier),
            NSPasteboard.PasteboardType(UTType.pdf.identifier),
        ]
    }

    public func dropPayload(for pasteboard: NSPasteboard) -> DropPayload? {
        if let data = pasteboard.data(
            forType: NSPasteboard.PasteboardType(UTType.yoPDFPaneDrag.identifier)
        ), let payload = try? JSONDecoder().decode(PaneDragPayload.self, from: data) {
            return .pane(payload)
        }
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let url = urls.first, url.isFileURL {
            return .fileURL(url)
        }
        return nil
    }

    @discardableResult
    public func draggingUpdated(_ draggingInfo: NSDraggingInfo, in view: NSView) -> NSDragOperation? {
        guard let sink, let payload = dropPayload(for: draggingInfo.draggingPasteboard) else {
            return nil
        }
        let point = view.convert(draggingInfo.draggingLocation, from: nil)
        let topLeftPoint = view.isFlipped ? point : CGPoint(x: point.x, y: view.bounds.height - point.y)
        let zone = PaneDropZone.zone(
            for: topLeftPoint,
            in: view.bounds.size,
            previousZone: activeZone,
            hysteresis: 0.05
        )
        activeZone = zone
        let check = sink.validate(payload, zone)
        sink.onHoverChanged(PaneDropHoverState(
            zone: zone,
            isValid: check.isValid,
            feedbackMessage: check.feedback
        ))
        return check.isValid ? sink.dropOperation(for: payload) : []
    }

    public func performDragOperation(_ draggingInfo: NSDraggingInfo, in view: NSView) -> Bool? {
        defer { conclude() }
        guard let sink, let payload = dropPayload(for: draggingInfo.draggingPasteboard) else {
            return nil
        }
        let point = view.convert(draggingInfo.draggingLocation, from: nil)
        let topLeftPoint = view.isFlipped ? point : CGPoint(x: point.x, y: view.bounds.height - point.y)
        let zone = activeZone ?? PaneDropZone.zone(
            for: topLeftPoint,
            in: view.bounds.size
        )
        return sink.onPerformDrop(payload, zone)
    }

    public func conclude() {
        activeZone = nil
        sink?.onHoverChanged(nil)
    }
}
