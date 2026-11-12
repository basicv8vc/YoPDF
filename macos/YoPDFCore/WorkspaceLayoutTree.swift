//
//  WorkspaceLayoutTree.swift
//  YoPDFCore
//
//  Created for Task P0-B-A: Multi-Pane Research Workspace Layout Core.
//  Apache-2.0 Open Source License.
//

import Foundation
import CoreGraphics

// MARK: - PaneID

/// Stable, strongly-typed identifier for a visual layout pane.
public struct PaneID: Hashable, Equatable, Sendable, Codable, Identifiable, CustomStringConvertible, RawRepresentable {
    public let rawValue: UUID

    public var id: UUID { rawValue }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public var description: String {
        rawValue.uuidString
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - SplitAxis

/// The geometric split orientation separating two sibling nodes in a binary layout tree.
public enum SplitAxis: String, Codable, Sendable {
    /// Left and right children separated by a vertical divider (horizontal distribution of width).
    case horizontal
    /// Top and bottom children separated by a horizontal divider (vertical distribution of height).
    case vertical
}

// MARK: - LayoutInsertionDirection

/// The target edge along which a new pane is inserted relative to an existing pane.
public enum LayoutInsertionDirection: String, Codable, Sendable {
    case left
    case right
    case top
    case bottom

    /// The split axis corresponding to this insertion direction.
    public var axis: SplitAxis {
        switch self {
        case .left, .right:
            return .horizontal
        case .top, .bottom:
            return .vertical
        }
    }

    /// Whether the newly inserted pane becomes the first child (`true`) or second child (`false`).
    public var isFirstChild: Bool {
        switch self {
        case .left, .top:
            return true
        case .right, .bottom:
            return false
        }
    }
}

// MARK: - LayoutMutationError

/// Errors encountered during layout tree mutations and validations.
public enum LayoutMutationError: Error, Equatable, Sendable {
    case targetPaneNotFound(PaneID)
    case duplicatePaneID(PaneID)
    case maximumPaneLimitReached(limit: Int)
    case insufficientSpace(required: CGFloat, available: CGFloat)
    case cannotCloseOnlyPane
}

// MARK: - LayoutPolicy

/// Configurable dimension, divider, and pane count constraints for layout calculation.
public struct LayoutPolicy: Equatable, Sendable {
    /// Minimum readable width for any visual leaf pane in logical points.
    public var minimumLeafWidth: CGFloat
    /// Minimum readable height for any visual leaf pane in logical points.
    public var minimumLeafHeight: CGFloat
    /// Physical divider thickness between split panes in logical points.
    public var dividerThickness: CGFloat
    /// Maximum allowable simultaneous panes per tab.
    public var maxPanes: Int

    public init(
        minimumLeafWidth: CGFloat = 320,
        minimumLeafHeight: CGFloat = 240,
        dividerThickness: CGFloat = 1,
        maxPanes: Int = 4
    ) {
        self.minimumLeafWidth = minimumLeafWidth
        self.minimumLeafHeight = minimumLeafHeight
        self.dividerThickness = dividerThickness
        self.maxPanes = maxPanes
    }

    /// Default baseline configuration per architecture contract.
    public static let `default` = LayoutPolicy()
}

// MARK: - LayoutNode

/// Recursive binary split tree node representing either a leaf visual pane or a binary split.
public indirect enum LayoutNode: Equatable, Sendable {
    case leaf(PaneID)
    case split(
        axis: SplitAxis,
        ratio: Double,
        first: LayoutNode,
        second: LayoutNode
    )
}

// MARK: - LayoutNode Codable Implementation

extension LayoutNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case paneID
        case axis
        case ratio
        case first
        case second
    }

    private enum NodeType: String, Codable {
        case leaf
        case split
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)

        switch type {
        case .leaf:
            let paneID = try container.decode(PaneID.self, forKey: .paneID)
            self = .leaf(paneID)

        case .split:
            let axis = try container.decode(SplitAxis.self, forKey: .axis)
            let ratio = try container.decode(Double.self, forKey: .ratio)
            guard ratio.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .ratio,
                    in: container,
                    debugDescription: "Split ratio must be a finite numerical value."
                )
            }
            let first = try container.decode(LayoutNode.self, forKey: .first)
            let second = try container.decode(LayoutNode.self, forKey: .second)
            self = .split(axis: axis, ratio: ratio, first: first, second: second)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let paneID):
            try container.encode(NodeType.leaf, forKey: .type)
            try container.encode(paneID, forKey: .paneID)
        case .split(let axis, let ratio, let first, let second):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(axis, forKey: .axis)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }
}

// MARK: - LayoutNode Operations

extension LayoutNode {
    /// Ordered list of all leaf PaneIDs contained in this subtree (depth-first traversal).
    public var leafIDs: [PaneID] {
        switch self {
        case .leaf(let id):
            return [id]
        case let .split(_, _, first, second):
            return first.leafIDs + second.leafIDs
        }
    }

    /// Total number of leaf visual panes hosted by this subtree.
    public var leafCount: Int {
        switch self {
        case .leaf:
            return 1
        case let .split(_, _, first, second):
            return first.leafCount + second.leafCount
        }
    }

    /// Returns `true` if the subtree contains a leaf with the specified PaneID.
    public func contains(_ paneID: PaneID) -> Bool {
        switch self {
        case .leaf(let id):
            return id == paneID
        case let .split(_, _, first, second):
            return first.contains(paneID) || second.contains(paneID)
        }
    }

    /// Calculates the minimum required size for this subtree in logical points using the supplied policy.
    public func minimumRequiredSize(policy: LayoutPolicy = .default) -> CGSize {
        switch self {
        case .leaf:
            return CGSize(width: policy.minimumLeafWidth, height: policy.minimumLeafHeight)

        case let .split(axis, _, first, second):
            let firstSize = first.minimumRequiredSize(policy: policy)
            let secondSize = second.minimumRequiredSize(policy: policy)

            switch axis {
            case .horizontal:
                return CGSize(
                    width: firstSize.width + policy.dividerThickness + secondSize.width,
                    height: max(firstSize.height, secondSize.height)
                )
            case .vertical:
                return CGSize(
                    width: max(firstSize.width, secondSize.width),
                    height: firstSize.height + policy.dividerThickness + secondSize.height
                )
            }
        }
    }

    /// Calculates the valid range of split ratios `[r_min, r_max]` for a container dimension.
    /// Returns `nil` if the container dimension is insufficient to host both children and the divider.
    public static func allowableRatioRange(
        axis: SplitAxis,
        first: LayoutNode,
        second: LayoutNode,
        in containerDimension: CGFloat,
        policy: LayoutPolicy = .default
    ) -> ClosedRange<Double>? {
        let availableSpace = containerDimension - policy.dividerThickness
        guard availableSpace > 0 else { return nil }

        let firstMin: CGFloat
        let secondMin: CGFloat
        switch axis {
        case .horizontal:
            firstMin = first.minimumRequiredSize(policy: policy).width
            secondMin = second.minimumRequiredSize(policy: policy).width
        case .vertical:
            firstMin = first.minimumRequiredSize(policy: policy).height
            secondMin = second.minimumRequiredSize(policy: policy).height
        }

        guard availableSpace >= (firstMin + secondMin) else {
            return nil
        }

        let rMin = Double(firstMin / availableSpace)
        let rMax = Double(1.0 - (secondMin / availableSpace))

        guard rMin <= rMax else { return nil }
        return rMin...rMax
    }

    /// Clamps a proposed split ratio to respect minimum dimensions for both children.
    ///
    /// - Normalizes non-finite ratios (NaN, positive/negative infinity) to a safe default candidate,
    ///   then constrains that candidate against the allowable `[r_min, r_max]` range.
    /// - If the container dimension is insufficient to satisfy both child minimums,
    ///   apportions space proportionally based on child minimum requirements.
    public static func clampedRatio(
        _ proposedRatio: Double,
        axis: SplitAxis,
        first: LayoutNode,
        second: LayoutNode,
        in containerDimension: CGFloat,
        policy: LayoutPolicy = .default
    ) -> Double {
        let candidate: Double
        if proposedRatio.isFinite {
            candidate = proposedRatio
        } else if proposedRatio == .infinity {
            candidate = 1.0
        } else if proposedRatio == -.infinity {
            candidate = 0.0
        } else {
            // NaN
            candidate = 0.5
        }

        if let validRange = allowableRatioRange(
            axis: axis,
            first: first,
            second: second,
            in: containerDimension,
            policy: policy
        ) {
            return min(max(candidate, validRange.lowerBound), validRange.upperBound)
        }

        // Fallback when container dimension is below the sum of minimum dimensions:
        // Apportion space proportionally based on child minimum requirements.
        let firstMin: CGFloat
        let secondMin: CGFloat
        switch axis {
        case .horizontal:
            firstMin = first.minimumRequiredSize(policy: policy).width
            secondMin = second.minimumRequiredSize(policy: policy).width
        case .vertical:
            firstMin = first.minimumRequiredSize(policy: policy).height
            secondMin = second.minimumRequiredSize(policy: policy).height
        }
        let total = firstMin + secondMin
        if total > 0 {
            return Double(firstMin / total)
        }
        return min(max(candidate, 0.0), 1.0)
    }

    /// Calculates the layout frames for each leaf pane hosted in this subtree within the given rectangle.
    public func paneFrames(in rect: CGRect, policy: LayoutPolicy = .default) -> [PaneID: CGRect] {
        switch self {
        case .leaf(let paneID):
            return [paneID: rect]

        case let .split(axis, ratio, first, second):
            var result: [PaneID: CGRect] = [:]
            let divider = policy.dividerThickness

            switch axis {
            case .horizontal:
                let availableWidth = max(0, rect.width - divider)
                let clamped = LayoutNode.clampedRatio(
                    ratio,
                    axis: .horizontal,
                    first: first,
                    second: second,
                    in: rect.width,
                    policy: policy
                )
                let firstWidth = availableWidth * CGFloat(clamped)
                let secondWidth = availableWidth - firstWidth

                let firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: firstWidth,
                    height: rect.height
                )
                let secondRect = CGRect(
                    x: rect.minX + firstWidth + divider,
                    y: rect.minY,
                    width: secondWidth,
                    height: rect.height
                )

                result.merge(first.paneFrames(in: firstRect, policy: policy)) { current, _ in current }
                result.merge(second.paneFrames(in: secondRect, policy: policy)) { current, _ in current }

            case .vertical:
                let availableHeight = max(0, rect.height - divider)
                let clamped = LayoutNode.clampedRatio(
                    ratio,
                    axis: .vertical,
                    first: first,
                    second: second,
                    in: rect.height,
                    policy: policy
                )
                let firstHeight = availableHeight * CGFloat(clamped)
                let secondHeight = availableHeight - firstHeight

                let firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: firstHeight
                )
                let secondRect = CGRect(
                    x: rect.minX,
                    y: rect.minY + firstHeight + divider,
                    width: rect.width,
                    height: secondHeight
                )

                result.merge(first.paneFrames(in: firstRect, policy: policy)) { current, _ in current }
                result.merge(second.paneFrames(in: secondRect, policy: policy)) { current, _ in current }
            }

            return result
        }
    }

    /// Calculates the divider rectangles for all splits in this subtree within the given rectangle.
    public func dividerFrames(in rect: CGRect, policy: LayoutPolicy = .default) -> [CGRect] {
        switch self {
        case .leaf:
            return []

        case let .split(axis, ratio, first, second):
            var result: [CGRect] = []
            let divider = policy.dividerThickness

            switch axis {
            case .horizontal:
                let availableWidth = max(0, rect.width - divider)
                let clamped = LayoutNode.clampedRatio(
                    ratio,
                    axis: .horizontal,
                    first: first,
                    second: second,
                    in: rect.width,
                    policy: policy
                )
                let firstWidth = availableWidth * CGFloat(clamped)
                let secondWidth = availableWidth - firstWidth

                let dividerRect = CGRect(
                    x: rect.minX + firstWidth,
                    y: rect.minY,
                    width: divider,
                    height: rect.height
                )
                result.append(dividerRect)

                let firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: firstWidth,
                    height: rect.height
                )
                let secondRect = CGRect(
                    x: rect.minX + firstWidth + divider,
                    y: rect.minY,
                    width: secondWidth,
                    height: rect.height
                )

                result.append(contentsOf: first.dividerFrames(in: firstRect, policy: policy))
                result.append(contentsOf: second.dividerFrames(in: secondRect, policy: policy))

            case .vertical:
                let availableHeight = max(0, rect.height - divider)
                let clamped = LayoutNode.clampedRatio(
                    ratio,
                    axis: .vertical,
                    first: first,
                    second: second,
                    in: rect.height,
                    policy: policy
                )
                let firstHeight = availableHeight * CGFloat(clamped)
                let secondHeight = availableHeight - firstHeight

                let dividerRect = CGRect(
                    x: rect.minX,
                    y: rect.minY + firstHeight,
                    width: rect.width,
                    height: divider
                )
                result.append(dividerRect)

                let firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: firstHeight
                )
                let secondRect = CGRect(
                    x: rect.minX,
                    y: rect.minY + firstHeight + divider,
                    width: rect.width,
                    height: secondHeight
                )

                result.append(contentsOf: first.dividerFrames(in: firstRect, policy: policy))
                result.append(contentsOf: second.dividerFrames(in: secondRect, policy: policy))
            }

            return result
        }
    }

    /// Replaces the target pane leaf with a split containing the new pane and target pane.
    func inserting(
        _ newPaneID: PaneID,
        adjacentTo target: PaneID,
        direction: LayoutInsertionDirection,
        ratio: Double = 0.5
    ) throws -> LayoutNode {
        switch self {
        case .leaf(let id):
            if id == target {
                let clampedRatio = min(max(ratio, 0.05), 0.95)
                switch direction {
                case .left:
                    return .split(
                        axis: .horizontal,
                        ratio: clampedRatio,
                        first: .leaf(newPaneID),
                        second: .leaf(target)
                    )
                case .right:
                    return .split(
                        axis: .horizontal,
                        ratio: clampedRatio,
                        first: .leaf(target),
                        second: .leaf(newPaneID)
                    )
                case .top:
                    return .split(
                        axis: .vertical,
                        ratio: clampedRatio,
                        first: .leaf(newPaneID),
                        second: .leaf(target)
                    )
                case .bottom:
                    return .split(
                        axis: .vertical,
                        ratio: clampedRatio,
                        first: .leaf(target),
                        second: .leaf(newPaneID)
                    )
                }
            } else {
                return self
            }

        case let .split(axis, splitRatio, first, second):
            if first.contains(target) {
                let newFirst = try first.inserting(newPaneID, adjacentTo: target, direction: direction, ratio: ratio)
                return .split(axis: axis, ratio: splitRatio, first: newFirst, second: second)
            } else if second.contains(target) {
                let newSecond = try second.inserting(newPaneID, adjacentTo: target, direction: direction, ratio: ratio)
                return .split(axis: axis, ratio: splitRatio, first: first, second: newSecond)
            } else {
                return self
            }
        }
    }

    /// Removes the specified pane ID from this subtree.
    /// Returns the surviving node, or `nil` if this entire subtree was the removed pane.
    func removing(_ paneID: PaneID) -> LayoutNode? {
        switch self {
        case .leaf(let id):
            if id == paneID {
                return nil
            }
            return self

        case let .split(axis, ratio, first, second):
            let newFirst = first.removing(paneID)
            let newSecond = second.removing(paneID)

            switch (newFirst, newSecond) {
            case (nil, nil):
                return nil
            case (let surviving?, nil):
                return surviving
            case (nil, let surviving?):
                return surviving
            case (let f?, let s?):
                return .split(axis: axis, ratio: ratio, first: f, second: s)
            }
        }
    }

    /// Performs purely structural normalization:
    /// - Drops unbacked leaves not found in `validPaneIDs`.
    /// - Drops duplicate leaf IDs.
    /// - Drops leaves exceeding `policy.maxPanes`.
    /// - Collapses empty splits (`nil, nil -> nil`).
    /// - Collapses single-child splits (`surviving, nil -> surviving`, `nil, surviving -> surviving`).
    func structurallyNormalized(
        validPaneIDs: Set<PaneID>?,
        seenPaneIDs: inout Set<PaneID>,
        policy: LayoutPolicy
    ) -> LayoutNode? {
        switch self {
        case .leaf(let id):
            if let validPaneIDs, !validPaneIDs.contains(id) {
                return nil
            }
            if seenPaneIDs.contains(id) {
                return nil
            }
            if seenPaneIDs.count >= policy.maxPanes {
                return nil
            }
            seenPaneIDs.insert(id)
            return .leaf(id)

        case let .split(axis, ratio, first, second):
            let normFirst = first.structurallyNormalized(
                validPaneIDs: validPaneIDs,
                seenPaneIDs: &seenPaneIDs,
                policy: policy
            )
            let normSecond = second.structurallyNormalized(
                validPaneIDs: validPaneIDs,
                seenPaneIDs: &seenPaneIDs,
                policy: policy
            )

            switch (normFirst, normSecond) {
            case (nil, nil):
                return nil
            case (let surviving?, nil):
                return surviving
            case (nil, let surviving?):
                return surviving
            case (let f?, let s?):
                return .split(axis: axis, ratio: ratio, first: f, second: s)
            }
        }
    }

    /// Performs geometry normalization on a structurally valid subtree:
    /// - When `containerSize` is provided: computes the actual allocated dimensions for each child,
    ///   clamps the split ratio against its allocated container dimension, and propagates
    ///   the resulting sub-container sizes recursively to nested splits.
    /// - When `containerSize` is `nil`: normalizes non-finite ratios to safe candidates and clamps to `[0.05, 0.95]`.
    func geometryNormalized(
        in containerSize: CGSize?,
        policy: LayoutPolicy
    ) -> LayoutNode {
        switch self {
        case .leaf:
            return self

        case let .split(axis, ratio, first, second):
            guard let containerSize else {
                let clamped: Double
                if !ratio.isFinite {
                    clamped = 0.5
                } else {
                    clamped = min(max(ratio, 0.05), 0.95)
                }
                return .split(
                    axis: axis,
                    ratio: clamped,
                    first: first.geometryNormalized(in: nil, policy: policy),
                    second: second.geometryNormalized(in: nil, policy: policy)
                )
            }

            let totalDim = (axis == .horizontal ? containerSize.width : containerSize.height)
            let clamped = LayoutNode.clampedRatio(
                ratio,
                axis: axis,
                first: first,
                second: second,
                in: totalDim,
                policy: policy
            )

            let availableSpace = max(0, totalDim - policy.dividerThickness)
            let firstDim = availableSpace * CGFloat(clamped)
            let secondDim = availableSpace - firstDim

            let firstSize: CGSize
            let secondSize: CGSize
            switch axis {
            case .horizontal:
                firstSize = CGSize(width: firstDim, height: containerSize.height)
                secondSize = CGSize(width: secondDim, height: containerSize.height)
            case .vertical:
                firstSize = CGSize(width: containerSize.width, height: firstDim)
                secondSize = CGSize(width: containerSize.width, height: secondDim)
            }

            let normFirst = first.geometryNormalized(in: firstSize, policy: policy)
            let normSecond = second.geometryNormalized(in: secondSize, policy: policy)

            return .split(axis: axis, ratio: clamped, first: normFirst, second: normSecond)
        }
    }

    /// Recursively normalizes the subtree:
    /// 1. Structural normalization: prunes invalid and duplicate leaves, collapses empty/single-child splits.
    /// 2. Geometry normalization: propagates actual allocated child dimensions and clamps ratios accordingly.
    func normalized(
        validPaneIDs: Set<PaneID>?,
        seenPaneIDs: inout Set<PaneID>,
        containerSize: CGSize?,
        policy: LayoutPolicy
    ) -> LayoutNode? {
        guard let structural = structurallyNormalized(
            validPaneIDs: validPaneIDs,
            seenPaneIDs: &seenPaneIDs,
            policy: policy
        ) else {
            return nil
        }
        return structural.geometryNormalized(in: containerSize, policy: policy)
    }
}

// MARK: - WorkspaceLayoutTree

/// Complete geometric layout tree for a workspace tab, hosting 1..N visual panes.
public struct WorkspaceLayoutTree: Equatable, Sendable, Codable {
    /// Root node of the binary layout hierarchy.
    public private(set) var root: LayoutNode

    public init(leaf: PaneID) {
        self.root = .leaf(leaf)
    }

    public init(root: LayoutNode) {
        self.root = root
    }

    /// Ordered list of all leaf PaneIDs in the tree.
    public var leafIDs: [PaneID] {
        root.leafIDs
    }

    /// Total number of panes in the tree.
    public var paneCount: Int {
        root.leafCount
    }

    /// Checks whether the tree contains the specified pane.
    public func contains(_ paneID: PaneID) -> Bool {
        root.contains(paneID)
    }

    /// Calculates the minimum required size for the entire tree in logical points.
    public func minimumRequiredSize(policy: LayoutPolicy = .default) -> CGSize {
        root.minimumRequiredSize(policy: policy)
    }

    /// Calculates the layout frames for each leaf pane within the given rectangle.
    public func paneFrames(in rect: CGRect, policy: LayoutPolicy = .default) -> [PaneID: CGRect] {
        root.paneFrames(in: rect, policy: policy)
    }

    /// Calculates the layout frames for each leaf pane within the given container size (origin at zero).
    public func paneFrames(in size: CGSize, policy: LayoutPolicy = .default) -> [PaneID: CGRect] {
        paneFrames(in: CGRect(origin: .zero, size: size), policy: policy)
    }

    /// Returns the frame for a specific pane within the container size, or `nil` if not found.
    public func frame(for paneID: PaneID, in size: CGSize, policy: LayoutPolicy = .default) -> CGRect? {
        paneFrames(in: size, policy: policy)[paneID]
    }

    /// Calculates the divider rectangles for all splits within the given rectangle.
    public func dividerFrames(in rect: CGRect, policy: LayoutPolicy = .default) -> [CGRect] {
        root.dividerFrames(in: rect, policy: policy)
    }

    /// Calculates the divider rectangles for all splits within the given container size.
    public func dividerFrames(in size: CGSize, policy: LayoutPolicy = .default) -> [CGRect] {
        dividerFrames(in: CGRect(origin: .zero, size: size), policy: policy)
    }

    /// Inserts a new pane adjacent to the target pane along the specified direction.
    ///
    /// Throws `LayoutMutationError` if:
    /// - The target pane does not exist (`.targetPaneNotFound`).
    /// - The new pane ID already exists in the tree (`.duplicatePaneID`).
    /// - The tree has reached or exceeded `policy.maxPanes` (`.maximumPaneLimitReached`).
    /// - `availableSize` is provided and the target pane or total tree cannot satisfy minimum dimensions (`.insufficientSpace`).
    public func inserting(
        _ newPaneID: PaneID,
        adjacentTo target: PaneID,
        direction: LayoutInsertionDirection,
        ratio: Double = 0.5,
        policy: LayoutPolicy = .default,
        availableSize: CGSize? = nil
    ) throws -> WorkspaceLayoutTree {
        guard contains(target) else {
            throw LayoutMutationError.targetPaneNotFound(target)
        }
        guard !contains(newPaneID) else {
            throw LayoutMutationError.duplicatePaneID(newPaneID)
        }
        guard paneCount < policy.maxPanes else {
            throw LayoutMutationError.maximumPaneLimitReached(limit: policy.maxPanes)
        }

        if let availableSize {
            // Check container dimension along the split axis
            let existingFrames = paneFrames(in: availableSize, policy: policy)
            guard let targetFrame = existingFrames[target] else {
                throw LayoutMutationError.targetPaneNotFound(target)
            }

            switch direction.axis {
            case .horizontal:
                let requiredWidth = policy.minimumLeafWidth * 2 + policy.dividerThickness
                if targetFrame.width < requiredWidth {
                    throw LayoutMutationError.insufficientSpace(required: requiredWidth, available: targetFrame.width)
                }
                if targetFrame.height < policy.minimumLeafHeight {
                    throw LayoutMutationError.insufficientSpace(required: policy.minimumLeafHeight, available: targetFrame.height)
                }
            case .vertical:
                let requiredHeight = policy.minimumLeafHeight * 2 + policy.dividerThickness
                if targetFrame.height < requiredHeight {
                    throw LayoutMutationError.insufficientSpace(required: requiredHeight, available: targetFrame.height)
                }
                if targetFrame.width < policy.minimumLeafWidth {
                    throw LayoutMutationError.insufficientSpace(required: policy.minimumLeafWidth, available: targetFrame.width)
                }
            }
        }

        let newRoot = try root.inserting(newPaneID, adjacentTo: target, direction: direction, ratio: ratio)

        if let availableSize {
            let requiredTotal = newRoot.minimumRequiredSize(policy: policy)
            if availableSize.width < requiredTotal.width {
                throw LayoutMutationError.insufficientSpace(required: requiredTotal.width, available: availableSize.width)
            }
            if availableSize.height < requiredTotal.height {
                throw LayoutMutationError.insufficientSpace(required: requiredTotal.height, available: availableSize.height)
            }
        }

        return WorkspaceLayoutTree(root: newRoot)
    }

    /// Mutating variant of `inserting`.
    public mutating func insert(
        _ newPaneID: PaneID,
        adjacentTo target: PaneID,
        direction: LayoutInsertionDirection,
        ratio: Double = 0.5,
        policy: LayoutPolicy = .default,
        availableSize: CGSize? = nil
    ) throws {
        self = try inserting(
            newPaneID,
            adjacentTo: target,
            direction: direction,
            ratio: ratio,
            policy: policy,
            availableSize: availableSize
        )
    }

    /// Removes a pane from the tree, automatically collapsing its parent split node.
    ///
    /// Throws `LayoutMutationError` if:
    /// - The pane ID does not exist (`.targetPaneNotFound`).
    /// - The tree only contains this single pane (`.cannotCloseOnlyPane`).
    public func removing(_ paneID: PaneID) throws -> WorkspaceLayoutTree {
        guard contains(paneID) else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }
        if case .leaf = root {
            throw LayoutMutationError.cannotCloseOnlyPane
        }
        guard let newRoot = root.removing(paneID) else {
            throw LayoutMutationError.cannotCloseOnlyPane
        }
        return WorkspaceLayoutTree(root: newRoot)
    }

    /// Mutating variant of `removing`.
    public mutating func remove(_ paneID: PaneID) throws {
        self = try removing(paneID)
    }

    /// Normalizes semantically invalid decoded layouts:
    /// 1. Prunes duplicate `PaneID` leaves.
    /// 2. Prunes leaves not found in `validPaneIDs` (unbacked descriptors).
    /// 3. Collapses empty or single-child split structures.
    /// 4. Clamps invalid or non-finite split ratios.
    /// 5. Enforces `policy.maxPanes`.
    /// 6. If the entire tree collapses or cannot fit `containerSize`, returns a fallback tree if `fallbackPaneID` is provided.
    public func normalized(
        validPaneIDs: Set<PaneID>? = nil,
        fallbackPaneID: PaneID? = nil,
        in containerSize: CGSize? = nil,
        policy: LayoutPolicy = .default
    ) -> WorkspaceLayoutTree? {
        var seen = Set<PaneID>()
        guard let newRoot = root.normalized(
            validPaneIDs: validPaneIDs,
            seenPaneIDs: &seen,
            containerSize: containerSize,
            policy: policy
        ) else {
            if let fallbackPaneID {
                return WorkspaceLayoutTree(leaf: fallbackPaneID)
            }
            return nil
        }

        if let containerSize, let fallbackPaneID {
            let minSize = newRoot.minimumRequiredSize(policy: policy)
            if containerSize.width < minSize.width || containerSize.height < minSize.height {
                return WorkspaceLayoutTree(leaf: fallbackPaneID)
            }
        }

        return WorkspaceLayoutTree(root: newRoot)
    }

    /// Mutating variant of `normalized`. Falls back to a clean single-pane tree if provided, or leaves unchanged if nil.
    public mutating func normalize(
        validPaneIDs: Set<PaneID>? = nil,
        fallbackPaneID: PaneID? = nil,
        in containerSize: CGSize? = nil,
        policy: LayoutPolicy = .default
    ) {
        if let normalized = normalized(
            validPaneIDs: validPaneIDs,
            fallbackPaneID: fallbackPaneID,
            in: containerSize,
            policy: policy
        ) {
            self = normalized
        }
    }
}
