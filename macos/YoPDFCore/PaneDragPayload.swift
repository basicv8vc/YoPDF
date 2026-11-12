//
//  PaneDragPayload.swift
//  YoPDFCore
//
//  Created for Task P0-B-D: Native Pane Drag & Drop.
//  Apache-2.0 Open Source License.
//

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

/// Hover state describing target insertion direction and validation for drop preview.
public struct PaneDropHoverState: Equatable, Sendable {
    public let direction: LayoutInsertionDirection
    public let isValid: Bool
    public let feedbackMessage: String

    public init(direction: LayoutInsertionDirection, isValid: Bool, feedbackMessage: String = "") {
        self.direction = direction
        self.isValid = isValid
        self.feedbackMessage = feedbackMessage
    }
}
