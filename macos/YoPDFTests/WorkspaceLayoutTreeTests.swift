//
//  WorkspaceLayoutTreeTests.swift
//  YoPDFTests
//
//  Created for Task P0-B-A: Multi-Pane Research Workspace Layout Core & Spike.
//  Apache-2.0 Open Source License.
//

import XCTest
@testable import YoPDFCore

final class WorkspaceLayoutTreeTests: XCTestCase {

    // MARK: - 1. Horizontal and Vertical Splits

    func testHorizontalAndVerticalSplits() throws {
        let paneA = PaneID()
        let paneB = PaneID()
        let paneC = PaneID()

        // Single pane root
        var tree = WorkspaceLayoutTree(leaf: paneA)
        XCTAssertEqual(tree.paneCount, 1)
        XCTAssertEqual(tree.leafIDs, [paneA])
        XCTAssertTrue(tree.contains(paneA))
        XCTAssertFalse(tree.contains(paneB))

        // Horizontal split: Insert B to the right of A
        try tree.insert(paneB, adjacentTo: paneA, direction: .right)
        XCTAssertEqual(tree.paneCount, 2)
        XCTAssertEqual(tree.leafIDs, [paneA, paneB])
        XCTAssertTrue(tree.contains(paneA))
        XCTAssertTrue(tree.contains(paneB))

        if case let .split(axis, ratio, first, second) = tree.root {
            XCTAssertEqual(axis, .horizontal)
            XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
            XCTAssertEqual(first, .leaf(paneA))
            XCTAssertEqual(second, .leaf(paneB))
        } else {
            XCTFail("Expected horizontal split root")
        }

        // Vertical split: Insert C below A
        try tree.insert(paneC, adjacentTo: paneA, direction: .bottom)
        XCTAssertEqual(tree.paneCount, 3)
        XCTAssertEqual(tree.leafIDs, [paneA, paneC, paneB])

        if case let .split(axis, _, first, second) = tree.root {
            XCTAssertEqual(axis, .horizontal)
            XCTAssertEqual(second, .leaf(paneB))
            if case let .split(subAxis, subRatio, subFirst, subSecond) = first {
                XCTAssertEqual(subAxis, .vertical)
                XCTAssertEqual(subRatio, 0.5, accuracy: 0.001)
                XCTAssertEqual(subFirst, .leaf(paneA))
                XCTAssertEqual(subSecond, .leaf(paneC))
            } else {
                XCTFail("Expected nested vertical split under first child")
            }
        } else {
            XCTFail("Expected horizontal split root")
        }
    }

    // MARK: - 2. Four-Direction Insertion

    func testFourDirectionInsertion() throws {
        let base = PaneID()

        // Direction .left -> new pane is first child, target is second child
        do {
            let leftPane = PaneID()
            let tree = try WorkspaceLayoutTree(leaf: base).inserting(leftPane, adjacentTo: base, direction: .left)
            XCTAssertEqual(tree.leafIDs, [leftPane, base])
            guard case let .split(axis, _, first, second) = tree.root else {
                return XCTFail("Expected split")
            }
            XCTAssertEqual(axis, .horizontal)
            XCTAssertEqual(first, .leaf(leftPane))
            XCTAssertEqual(second, .leaf(base))
        }

        // Direction .right -> target is first child, new pane is second child
        do {
            let rightPane = PaneID()
            let tree = try WorkspaceLayoutTree(leaf: base).inserting(rightPane, adjacentTo: base, direction: .right)
            XCTAssertEqual(tree.leafIDs, [base, rightPane])
            guard case let .split(axis, _, first, second) = tree.root else {
                return XCTFail("Expected split")
            }
            XCTAssertEqual(axis, .horizontal)
            XCTAssertEqual(first, .leaf(base))
            XCTAssertEqual(second, .leaf(rightPane))
        }

        // Direction .top -> new pane is first child, target is second child
        do {
            let topPane = PaneID()
            let tree = try WorkspaceLayoutTree(leaf: base).inserting(topPane, adjacentTo: base, direction: .top)
            XCTAssertEqual(tree.leafIDs, [topPane, base])
            guard case let .split(axis, _, first, second) = tree.root else {
                return XCTFail("Expected split")
            }
            XCTAssertEqual(axis, .vertical)
            XCTAssertEqual(first, .leaf(topPane))
            XCTAssertEqual(second, .leaf(base))
        }

        // Direction .bottom -> target is first child, new pane is second child
        do {
            let bottomPane = PaneID()
            let tree = try WorkspaceLayoutTree(leaf: base).inserting(bottomPane, adjacentTo: base, direction: .bottom)
            XCTAssertEqual(tree.leafIDs, [base, bottomPane])
            guard case let .split(axis, _, first, second) = tree.root else {
                return XCTFail("Expected split")
            }
            XCTAssertEqual(axis, .vertical)
            XCTAssertEqual(first, .leaf(base))
            XCTAssertEqual(second, .leaf(bottomPane))
        }
    }

    // MARK: - 3. Three-Level Nested Layouts

    func testThreeLevelNestedLayouts() throws {
        let p1 = PaneID()
        let p2 = PaneID()
        let p3 = PaneID()
        let p4 = PaneID()

        // Level 1: [P1]
        var tree = WorkspaceLayoutTree(leaf: p1)

        // Level 2: [P1 | P2] (horizontal)
        try tree.insert(p2, adjacentTo: p1, direction: .right)

        // Level 3: [P1 | (P2 / P3)] (P2 split vertically into P2 and P3)
        try tree.insert(p3, adjacentTo: p2, direction: .bottom)

        // Level 4 (depth 3 nested): [P1 | (P2 / (P4 | P3))] (P3 split horizontally with P4 to its left)
        try tree.insert(p4, adjacentTo: p3, direction: .left)

        XCTAssertEqual(tree.paneCount, 4)
        XCTAssertEqual(tree.leafIDs, [p1, p2, p4, p3])

        // Verify nested structure:
        // root: split(.horizontal, first: P1, second: split(.vertical, first: P2, second: split(.horizontal, first: P4, second: P3)))
        guard case let .split(rootAxis, _, rootFirst, rootSecond) = tree.root else {
            return XCTFail("Expected split root")
        }
        XCTAssertEqual(rootAxis, .horizontal)
        XCTAssertEqual(rootFirst, .leaf(p1))

        guard case let .split(subAxis1, _, subFirst1, subSecond1) = rootSecond else {
            return XCTFail("Expected sub split 1")
        }
        XCTAssertEqual(subAxis1, .vertical)
        XCTAssertEqual(subFirst1, .leaf(p2))

        guard case let .split(subAxis2, _, subFirst2, subSecond2) = subSecond1 else {
            return XCTFail("Expected sub split 2")
        }
        XCTAssertEqual(subAxis2, .horizontal)
        XCTAssertEqual(subFirst2, .leaf(p4))
        XCTAssertEqual(subSecond2, .leaf(p3))
    }

    // MARK: - 4. Geometry Calculation

    func testGeometryCalculation() throws {
        let p1 = PaneID()
        let p2 = PaneID()
        let p3 = PaneID()

        let policy = LayoutPolicy(
            minimumLeafWidth: 320,
            minimumLeafHeight: 240,
            dividerThickness: 2,
            maxPanes: 4
        )

        // Create horizontal split P1 and P2 with ratio 0.5
        // Container: 1002 x 600
        // Available width: 1002 - 2 = 1000
        // P1 width: 500, P2 width: 500
        var tree = WorkspaceLayoutTree(leaf: p1)
        try tree.insert(p2, adjacentTo: p1, direction: .right, ratio: 0.5, policy: policy)

        let frames2 = tree.paneFrames(in: CGSize(width: 1002, height: 600), policy: policy)
        XCTAssertEqual(frames2.count, 2)
        XCTAssertEqual(frames2[p1], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(frames2[p2], CGRect(x: 502, y: 0, width: 500, height: 600))

        // Split P2 vertically into P2 and P3 with ratio 0.5
        // Available height in P2: 600 - 2 = 598
        // P2 height: 299, P3 height: 299
        try tree.insert(p3, adjacentTo: p2, direction: .bottom, ratio: 0.5, policy: policy)

        let frames3 = tree.paneFrames(in: CGSize(width: 1002, height: 600), policy: policy)
        XCTAssertEqual(frames3.count, 3)
        XCTAssertEqual(frames3[p1], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(frames3[p2], CGRect(x: 502, y: 0, width: 500, height: 299))
        XCTAssertEqual(frames3[p3], CGRect(x: 502, y: 301, width: 500, height: 299))

        // Verify dividers
        let dividers = tree.dividerFrames(in: CGSize(width: 1002, height: 600), policy: policy)
        XCTAssertEqual(dividers.count, 2)
        XCTAssertEqual(dividers[0], CGRect(x: 500, y: 0, width: 2, height: 600))
        XCTAssertEqual(dividers[1], CGRect(x: 502, y: 299, width: 500, height: 2))
    }

    // MARK: - 5. Dynamic Ratio Clamping

    func testDynamicRatioClamping() throws {
        let p1 = PaneID()
        let p2 = PaneID()

        let policy = LayoutPolicy(
            minimumLeafWidth: 320,
            minimumLeafHeight: 240,
            dividerThickness: 1,
            maxPanes: 4
        )

        // Container width: 801 pt. Divider: 1 pt. Available: 800 pt.
        // firstMin: 320 -> rMin = 320 / 800 = 0.40
        // secondMin: 320 -> rMax = 1 - (320 / 800) = 0.60
        var tree = WorkspaceLayoutTree(leaf: p1)
        // Request ratio 0.1 (would give P1 80 pt without clamping)
        try tree.insert(p2, adjacentTo: p1, direction: .right, ratio: 0.1, policy: policy)

        let framesLow = tree.paneFrames(in: CGSize(width: 801, height: 500), policy: policy)
        guard let p1FrameLow = framesLow[p1], let p2FrameLow = framesLow[p2] else {
            return XCTFail("Missing frames")
        }
        XCTAssertEqual(p1FrameLow.width, 320, accuracy: 0.001)
        XCTAssertEqual(p2FrameLow.width, 480, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(p1FrameLow.width, policy.minimumLeafWidth)
        XCTAssertGreaterThanOrEqual(p2FrameLow.width, policy.minimumLeafWidth)

        // Request ratio 0.95 (would give P2 40 pt without clamping)
        let treeHigh = try WorkspaceLayoutTree(leaf: p1).inserting(
            p2,
            adjacentTo: p1,
            direction: .right,
            ratio: 0.95,
            policy: policy
        )
        let framesHigh = treeHigh.paneFrames(in: CGSize(width: 801, height: 500), policy: policy)
        guard let p1FrameHigh = framesHigh[p1], let p2FrameHigh = framesHigh[p2] else {
            return XCTFail("Missing frames")
        }
        XCTAssertEqual(p1FrameHigh.width, 480, accuracy: 0.001)
        XCTAssertEqual(p2FrameHigh.width, 320, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(p1FrameHigh.width, policy.minimumLeafWidth)
        XCTAssertGreaterThanOrEqual(p2FrameHigh.width, policy.minimumLeafWidth)

        // Test non-finite ratio (NaN, +Infinity, -Infinity) with symmetric children
        let treeNaN = WorkspaceLayoutTree(
            root: .split(axis: .horizontal, ratio: .nan, first: .leaf(p1), second: .leaf(p2))
        )
        let nanFrames = treeNaN.paneFrames(in: CGSize(width: 801, height: 500), policy: policy)
        XCTAssertEqual(nanFrames[p1]?.width ?? 0, 400, accuracy: 0.001)
        XCTAssertEqual(nanFrames[p2]?.width ?? 0, 400, accuracy: 0.001)

        let treePosInf = WorkspaceLayoutTree(
            root: .split(axis: .horizontal, ratio: .infinity, first: .leaf(p1), second: .leaf(p2))
        )
        let posInfFrames = treePosInf.paneFrames(in: CGSize(width: 801, height: 500), policy: policy)
        XCTAssertEqual(posInfFrames[p1]?.width ?? 0, 480, accuracy: 0.001)
        XCTAssertEqual(posInfFrames[p2]?.width ?? 0, 320, accuracy: 0.001)

        let treeNegInf = WorkspaceLayoutTree(
            root: .split(axis: .horizontal, ratio: -.infinity, first: .leaf(p1), second: .leaf(p2))
        )
        let negInfFrames = treeNegInf.paneFrames(in: CGSize(width: 801, height: 500), policy: policy)
        XCTAssertEqual(negInfFrames[p1]?.width ?? 0, 320, accuracy: 0.001)
        XCTAssertEqual(negInfFrames[p2]?.width ?? 0, 480, accuracy: 0.001)

        // Test non-finite ratio with ASYMMETRIC nested subtree minimum dimensions:
        // first child: leaf P1 (min width 320)
        // second child: horizontal split (P2 | P3) (min width 320 + 1 + 320 = 641)
        // Available width in 1001pt container: 1000pt.
        // rMin = 320 / 1000 = 0.320
        // rMax = 1 - (641 / 1000) = 0.359
        // A naive ratio of 0.5 would give first=500, second=500 (violating second's 641 minimum).
        // Safe candidate clamping MUST constrain NaN to rMax = 0.359.
        let p3 = PaneID()
        let asymmetricNestedRoot = LayoutNode.split(
            axis: .horizontal,
            ratio: .nan, // Non-finite!
            first: .leaf(p1),
            second: .split(
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(p2),
                second: .leaf(p3)
            )
        )
        let asymmetricTree = WorkspaceLayoutTree(root: asymmetricNestedRoot)
        let asymmetricFrames = asymmetricTree.paneFrames(in: CGSize(width: 1001, height: 500), policy: policy)
        guard let f1 = asymmetricFrames[p1], let f2 = asymmetricFrames[p2], let f3 = asymmetricFrames[p3] else {
            return XCTFail("Missing asymmetric frames")
        }
        XCTAssertGreaterThanOrEqual(f1.width, policy.minimumLeafWidth - 0.01)
        XCTAssertGreaterThanOrEqual(f2.width, policy.minimumLeafWidth - 0.01)
        XCTAssertGreaterThanOrEqual(f3.width, policy.minimumLeafWidth - 0.01)
        XCTAssertEqual(f1.width, 359, accuracy: 0.01)
        XCTAssertEqual(f2.width + policy.dividerThickness + f3.width, 641, accuracy: 0.01)

        // Insufficient container geometry with NaN
        let insufficientFrames = asymmetricTree.paneFrames(in: CGSize(width: 500, height: 500), policy: policy)
        XCTAssertGreaterThan(insufficientFrames[p1]?.width ?? 0, 0)
        XCTAssertGreaterThan(insufficientFrames[p2]?.width ?? 0, 0)
        XCTAssertGreaterThan(insufficientFrames[p3]?.width ?? 0, 0)
    }

    // MARK: - 6. Insufficient-Window-Size Refusal

    func testInsufficientWindowSizeRefusal() throws {
        let p1 = PaneID()
        let p2 = PaneID()
        let policy = LayoutPolicy(
            minimumLeafWidth: 320,
            minimumLeafHeight: 240,
            dividerThickness: 1,
            maxPanes: 4
        )

        let tree = WorkspaceLayoutTree(leaf: p1)

        // Minimum horizontal space required for 2 panes: 320 + 1 + 320 = 641
        // Passing container width 600 must throw .insufficientSpace
        XCTAssertThrowsError(
            try tree.inserting(
                p2,
                adjacentTo: p1,
                direction: .right,
                policy: policy,
                availableSize: CGSize(width: 600, height: 500)
            )
        ) { error in
            guard case let LayoutMutationError.insufficientSpace(required, available) = error else {
                return XCTFail("Expected .insufficientSpace, got \(error)")
            }
            XCTAssertEqual(required, 641)
            XCTAssertEqual(available, 600)
        }

        // Minimum vertical space required for 2 panes: 240 + 1 + 240 = 481
        // Passing container height 400 must throw .insufficientSpace
        XCTAssertThrowsError(
            try tree.inserting(
                p2,
                adjacentTo: p1,
                direction: .bottom,
                policy: policy,
                availableSize: CGSize(width: 800, height: 400)
            )
        ) { error in
            guard case let LayoutMutationError.insufficientSpace(required, available) = error else {
                return XCTFail("Expected .insufficientSpace, got \(error)")
            }
            XCTAssertEqual(required, 481)
            XCTAssertEqual(available, 400)
        }

        // Window with sufficient dimensions succeeds
        XCTAssertNoThrow(
            try tree.inserting(
                p2,
                adjacentTo: p1,
                direction: .right,
                policy: policy,
                availableSize: CGSize(width: 700, height: 500)
            )
        )
    }

    // MARK: - 7. Maximum Pane Count

    func testMaximumPaneCountEnforcement() throws {
        let p1 = PaneID()
        let p2 = PaneID()
        let p3 = PaneID()
        let p4 = PaneID()
        let p5 = PaneID()

        let policy = LayoutPolicy(
            minimumLeafWidth: 100,
            minimumLeafHeight: 100,
            dividerThickness: 1,
            maxPanes: 4
        )

        var tree = WorkspaceLayoutTree(leaf: p1)
        try tree.insert(p2, adjacentTo: p1, direction: .right, policy: policy)
        try tree.insert(p3, adjacentTo: p2, direction: .right, policy: policy)
        try tree.insert(p4, adjacentTo: p3, direction: .right, policy: policy)
        XCTAssertEqual(tree.paneCount, 4)

        // Attempting to insert a 5th pane must throw .maximumPaneLimitReached(limit: 4)
        XCTAssertThrowsError(
            try tree.insert(p5, adjacentTo: p4, direction: .right, policy: policy)
        ) { error in
            guard case let LayoutMutationError.maximumPaneLimitReached(limit) = error else {
                return XCTFail("Expected .maximumPaneLimitReached, got \(error)")
            }
            XCTAssertEqual(limit, 4)
        }

        // Custom policy with maxPanes = 2
        let customPolicy = LayoutPolicy(maxPanes: 2)
        var smallTree = WorkspaceLayoutTree(leaf: p1)
        try smallTree.insert(p2, adjacentTo: p1, direction: .right, policy: customPolicy)
        XCTAssertThrowsError(
            try smallTree.insert(p3, adjacentTo: p2, direction: .right, policy: customPolicy)
        ) { error in
            guard case let LayoutMutationError.maximumPaneLimitReached(limit) = error else {
                return XCTFail("Expected .maximumPaneLimitReached(2), got \(error)")
            }
            XCTAssertEqual(limit, 2)
        }
    }

    // MARK: - 8. Removing a Leaf and Collapsing Parent

    func testRemovingLeafAndCollapsingParent() throws {
        let p1 = PaneID()
        let p2 = PaneID()
        let p3 = PaneID()

        // 1. Single pane: removing only pane throws .cannotCloseOnlyPane
        var tree = WorkspaceLayoutTree(leaf: p1)
        XCTAssertThrowsError(try tree.remove(p1)) { error in
            XCTAssertEqual(error as? LayoutMutationError, .cannotCloseOnlyPane)
        }

        // 2. Target not found throws .targetPaneNotFound
        XCTAssertThrowsError(try tree.remove(p2)) { error in
            XCTAssertEqual(error as? LayoutMutationError, .targetPaneNotFound(p2))
        }

        // 3. Two panes: removing P1 leaves P2 as root leaf
        try tree.insert(p2, adjacentTo: p1, direction: .right)
        let treeAfterP1 = try tree.removing(p1)
        XCTAssertEqual(treeAfterP1.root, .leaf(p2))
        XCTAssertEqual(treeAfterP1.paneCount, 1)

        // 4. Removing P2 leaves P1 as root leaf
        let treeAfterP2 = try tree.removing(p2)
        XCTAssertEqual(treeAfterP2.root, .leaf(p1))
        XCTAssertEqual(treeAfterP2.paneCount, 1)

        // 5. Three panes: [P1 | (P2 / P3)]
        var tree3 = WorkspaceLayoutTree(leaf: p1)
        try tree3.insert(p2, adjacentTo: p1, direction: .right)
        try tree3.insert(p3, adjacentTo: p2, direction: .bottom)

        // Removing P2 collapses (P2 / P3) into P3 -> [P1 | P3]
        let treeWithoutP2 = try tree3.removing(p2)
        XCTAssertEqual(treeWithoutP2.paneCount, 2)
        XCTAssertEqual(treeWithoutP2.leafIDs, [p1, p3])
        if case let .split(axis, _, first, second) = treeWithoutP2.root {
            XCTAssertEqual(axis, .horizontal)
            XCTAssertEqual(first, .leaf(p1))
            XCTAssertEqual(second, .leaf(p3))
        } else {
            XCTFail("Expected horizontal split")
        }

        // Removing P1 collapses root into (P2 / P3)
        let treeWithoutP1 = try tree3.removing(p1)
        XCTAssertEqual(treeWithoutP1.paneCount, 2)
        XCTAssertEqual(treeWithoutP1.leafIDs, [p2, p3])
        if case let .split(axis, _, first, second) = treeWithoutP1.root {
            XCTAssertEqual(axis, .vertical)
            XCTAssertEqual(first, .leaf(p2))
            XCTAssertEqual(second, .leaf(p3))
        } else {
            XCTFail("Expected vertical split")
        }
    }

    // MARK: - 9. Duplicate PaneID Normalization

    func testDuplicatePaneIDNormalization() throws {
        let p1 = PaneID()
        let p2 = PaneID()

        // Create a malformed tree with duplicate leaf P1 in both children
        let malformedRoot = LayoutNode.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(p1),
            second: .split(
                axis: .vertical,
                ratio: 0.5,
                first: .leaf(p2),
                second: .leaf(p1) // Duplicate!
            )
        )
        let tree = WorkspaceLayoutTree(root: malformedRoot)
        XCTAssertEqual(tree.leafIDs, [p1, p2, p1])

        let normalized = tree.normalized()
        XCTAssertNotNil(normalized)
        XCTAssertEqual(normalized?.paneCount, 2)
        XCTAssertEqual(normalized?.leafIDs, [p1, p2])

        // Verify the second child collapsed from (P2 / P1) into P2
        if case let .split(axis, _, first, second) = normalized?.root {
            XCTAssertEqual(axis, .horizontal)
            XCTAssertEqual(first, .leaf(p1))
            XCTAssertEqual(second, .leaf(p2))
        } else {
            XCTFail("Expected horizontal split")
        }
    }

    // MARK: - 10. Missing PaneSession Descriptor Normalization

    func testMissingPaneSessionDescriptorNormalization() throws {
        let p1 = PaneID()
        let p2 = PaneID()
        let p3 = PaneID()

        // Tree has P1, P2, P3
        var tree = WorkspaceLayoutTree(leaf: p1)
        try tree.insert(p2, adjacentTo: p1, direction: .right)
        try tree.insert(p3, adjacentTo: p2, direction: .bottom)

        // Only P1 and P3 have active session descriptors; P2 is missing
        let validSessions: Set<PaneID> = [p1, p3]

        let normalized = tree.normalized(validPaneIDs: validSessions)
        XCTAssertNotNil(normalized)
        XCTAssertEqual(normalized?.paneCount, 2)
        XCTAssertEqual(normalized?.leafIDs, [p1, p3])

        // When all panes are invalid, normalization falls back to fallbackPaneID if provided
        let fallback = PaneID()
        let emptySessions: Set<PaneID> = []
        let fallbackTree = tree.normalized(validPaneIDs: emptySessions, fallbackPaneID: fallback)
        XCTAssertNotNil(fallbackTree)
        XCTAssertEqual(fallbackTree?.root, .leaf(fallback))
    }

    // MARK: - 11. Malformed Serialized Data Fails Decoding Safely

    func testMalformedSerializedDataFailsDecodingSafely() {
        let decoder = JSONDecoder()

        // Case 1: Corrupted JSON syntax
        let corruptedJSON = "{ invalid json syntax".data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(WorkspaceLayoutTree.self, from: corruptedJSON))

        // Case 2: Missing required field in split (missing "second")
        let missingFieldJSON = """
        {
            "root": {
                "type": "split",
                "axis": "horizontal",
                "ratio": 0.5,
                "first": {
                    "type": "leaf",
                    "paneID": "\(UUID().uuidString)"
                }
            }
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(WorkspaceLayoutTree.self, from: missingFieldJSON))

        // Case 3: Invalid type tag
        let invalidTypeJSON = """
        {
            "root": {
                "type": "circle",
                "paneID": "\(UUID().uuidString)"
            }
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(WorkspaceLayoutTree.self, from: invalidTypeJSON))

        // Case 4: Non-finite ratio (string "NaN")
        let nanRatioJSON = """
        {
            "root": {
                "type": "split",
                "axis": "horizontal",
                "ratio": "NaN",
                "first": { "type": "leaf", "paneID": "\(UUID().uuidString)" },
                "second": { "type": "leaf", "paneID": "\(UUID().uuidString)" }
            }
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(WorkspaceLayoutTree.self, from: nanRatioJSON))
    }

    // MARK: - 12. Codable Round-Trip

    func testCodableRoundTrip() throws {
        let p1 = PaneID()
        let p2 = PaneID()
        let p3 = PaneID()
        let p4 = PaneID()

        var original = WorkspaceLayoutTree(leaf: p1)
        try original.insert(p2, adjacentTo: p1, direction: .right, ratio: 0.4)
        try original.insert(p3, adjacentTo: p2, direction: .bottom, ratio: 0.6)
        try original.insert(p4, adjacentTo: p3, direction: .left, ratio: 0.5)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WorkspaceLayoutTree.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.leafIDs, original.leafIDs)
        XCTAssertEqual(decoded.paneCount, original.paneCount)

        // Frames match exactly
        let size = CGSize(width: 1200, height: 900)
        XCTAssertEqual(
            decoded.paneFrames(in: size),
            original.paneFrames(in: size)
        )
    }

    // MARK: - 13. Deterministic Normalization

    func testDeterministicNormalization() throws {
        let p1 = PaneID()
        let p2 = PaneID()

        let malformed = LayoutNode.split(
            axis: .horizontal,
            ratio: 1.5, // Out of bounds
            first: .leaf(p1),
            second: .split(
                axis: .vertical,
                ratio: -0.2, // Out of bounds
                first: .leaf(p1), // Duplicate
                second: .leaf(p2)
            )
        )
        let tree = WorkspaceLayoutTree(root: malformed)

        // Multiple normalization passes produce identical results
        let norm1 = tree.normalized()
        let norm2 = tree.normalized()
        let norm3 = tree.normalized()

        XCTAssertEqual(norm1, norm2)
        XCTAssertEqual(norm2, norm3)
        XCTAssertEqual(norm1?.leafIDs, [p1, p2])
    }

    // MARK: - 14. Architecture Contract Conformance (Section 12.1)

    func testRecursiveMinimumSizeCalculation() {
        let policy = LayoutPolicy(
            minimumLeafWidth: 320,
            minimumLeafHeight: 240,
            dividerThickness: 1,
            maxPanes: 4
        )

        let p1 = PaneID()
        let p2 = PaneID()
        let p3 = PaneID()

        // Single leaf: 320 x 240
        let leaf = LayoutNode.leaf(p1)
        XCTAssertEqual(leaf.minimumRequiredSize(policy: policy), CGSize(width: 320, height: 240))

        // Horizontal split of 2 leaves: (320 + 1 + 320) x max(240, 240) = 641 x 240
        let hSplit = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: .leaf(p1), second: .leaf(p2))
        XCTAssertEqual(hSplit.minimumRequiredSize(policy: policy), CGSize(width: 641, height: 240))

        // Vertical split of 2 leaves: max(320, 320) x (240 + 1 + 240) = 320 x 481
        let vSplit = LayoutNode.split(axis: .vertical, ratio: 0.5, first: .leaf(p1), second: .leaf(p2))
        XCTAssertEqual(vSplit.minimumRequiredSize(policy: policy), CGSize(width: 320, height: 481))

        // Nested: P1 | (P2 / P3):
        // (P2 / P3) requires 320 x 481
        // Root horizontal requires (320 + 1 + 320) x max(240, 481) = 641 x 481
        let nested = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: .leaf(p1), second: vSplit)
        XCTAssertEqual(nested.minimumRequiredSize(policy: policy), CGSize(width: 641, height: 481))
    }

    func testSplitRatioBoundingPreventsZeroPixelPanes() throws {
        let p1 = PaneID()
        let p2 = PaneID()
        let policy = LayoutPolicy(
            minimumLeafWidth: 320,
            minimumLeafHeight: 240,
            dividerThickness: 1,
            maxPanes: 4
        )

        let containerSize = CGSize(width: 1000, height: 800)
        // Available width = 1000 - 1 = 999
        // rMin = 320 / 999 ≈ 0.32032
        // rMax = 1 - 320 / 999 ≈ 0.67968

        var tree = WorkspaceLayoutTree(leaf: p1)
        // Request an extreme ratio of 0.0001
        try tree.insert(p2, adjacentTo: p1, direction: .right, ratio: 0.0001, policy: policy)
        let framesZero = tree.paneFrames(in: containerSize, policy: policy)

        guard let f1 = framesZero[p1], let f2 = framesZero[p2] else {
            return XCTFail("Frames missing")
        }
        XCTAssertGreaterThanOrEqual(f1.width, policy.minimumLeafWidth - 0.01)
        XCTAssertGreaterThanOrEqual(f2.width, policy.minimumLeafWidth - 0.01)
        XCTAssertEqual(f1.width + policy.dividerThickness + f2.width, containerSize.width, accuracy: 0.01)
    }

    func testInsufficientSpaceErrorThrownWhenWindowTooNarrow() {
        let p1 = PaneID()
        let p2 = PaneID()
        let policy = LayoutPolicy(
            minimumLeafWidth: 320,
            minimumLeafHeight: 240,
            dividerThickness: 1,
            maxPanes: 4
        )

        let tree = WorkspaceLayoutTree(leaf: p1)
        // Required horizontal space = 641, available = 500
        XCTAssertThrowsError(
            try tree.inserting(
                p2,
                adjacentTo: p1,
                direction: .right,
                policy: policy,
                availableSize: CGSize(width: 500, height: 500)
            )
        ) { error in
            guard case let LayoutMutationError.insufficientSpace(required, available) = error else {
                return XCTFail("Expected .insufficientSpace, got \(error)")
            }
            XCTAssertEqual(required, 641)
            XCTAssertEqual(available, 500)
        }
    }

    func testPruningLeafCollapsesParentSplitNode() throws {
        let p1 = PaneID()
        let p2 = PaneID()
        let p3 = PaneID()

        var tree = WorkspaceLayoutTree(leaf: p1)
        try tree.insert(p2, adjacentTo: p1, direction: .right)
        try tree.insert(p3, adjacentTo: p2, direction: .bottom)

        // Tree is P1 | (P2 / P3)
        // Pruning P3 should collapse (P2 / P3) into P2 -> P1 | P2
        let collapsed = try tree.removing(p3)
        XCTAssertEqual(collapsed.leafIDs, [p1, p2])
        guard case let .split(axis, _, first, second) = collapsed.root else {
            return XCTFail("Expected split")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(first, .leaf(p1))
        XCTAssertEqual(second, .leaf(p2))
    }

    func testDeserializationNormalizationRepairsCorruptedTree() {
        let p1 = PaneID()
        let p2 = PaneID()
        let unbackedPane = PaneID()

        let corruptedRoot = LayoutNode.split(
            axis: .horizontal,
            ratio: 2.0, // Invalid ratio
            first: .leaf(p1),
            second: .split(
                axis: .vertical,
                ratio: 0.5,
                first: .leaf(unbackedPane), // Unbacked
                second: .leaf(p2)
            )
        )
        let tree = WorkspaceLayoutTree(root: corruptedRoot)
        let validDescriptors: Set<PaneID> = [p1, p2]

        let sanitized = tree.normalized(validPaneIDs: validDescriptors)
        XCTAssertNotNil(sanitized)
        XCTAssertEqual(sanitized?.leafIDs, [p1, p2])
        if case let .split(axis, ratio, first, second) = sanitized?.root {
            XCTAssertEqual(axis, .horizontal)
            XCTAssertTrue(ratio >= 0.05 && ratio <= 0.95)
            XCTAssertEqual(first, .leaf(p1))
            XCTAssertEqual(second, .leaf(p2))
        } else {
            XCTFail("Expected sanitized split")
        }
    }

    // MARK: - 15. Nested Normalization Dimension Propagation Regression (CTO Review)

    func testNestedSplitNormalizationPropagatesAllocatedDimensions() {
        let p1 = PaneID()
        let p2 = PaneID()
        let p3 = PaneID()

        let policy = LayoutPolicy(
            minimumLeafWidth: 320,
            minimumLeafHeight: 240,
            dividerThickness: 1,
            maxPanes: 4
        )

        // Root horizontal split: container 1001 x 800 pt
        // Divider: 1 pt -> Available width = 1000 pt
        // Ratio = 0.35 -> P1 gets 350 pt, second subtree (P2 | P3) gets 650 pt
        // Inside second subtree: allocated width = 650 pt, divider = 1 pt -> available = 649 pt
        // Minimums: P2=320, P3=320 -> rMin = 320/649 ≈ 0.49306, rMax = 1 - 320/649 ≈ 0.50693
        // If the nested split had an unconstrained ratio of 0.85:
        // - In old code: clamped against 1001pt (rMax = 0.679), yielding 0.679 * 649 = 440.6pt for P2,
        //   leaving only 208.4pt for P3 (< 320pt minimum violation!).
        // - In corrected code: geometry normalization passes the allocated 650pt to the nested split,
        //   clamping its ratio to rMax = 0.50693, guaranteeing P3 >= 320pt!
        let tree = WorkspaceLayoutTree(
            root: .split(
                axis: .horizontal,
                ratio: 0.35,
                first: .leaf(p1),
                second: .split(
                    axis: .horizontal,
                    ratio: 0.85, // Persisted out-of-bounds ratio for 650pt container
                    first: .leaf(p2),
                    second: .leaf(p3)
                )
            )
        )

        let containerSize = CGSize(width: 1001, height: 800)
        guard let normalizedTree = tree.normalized(in: containerSize, policy: policy) else {
            return XCTFail("Normalization should succeed")
        }

        // Verify persisted ratio in normalized tree
        guard case let .split(_, rootRatio, _, secondNode) = normalizedTree.root else {
            return XCTFail("Expected split root")
        }
        XCTAssertEqual(rootRatio, 0.35, accuracy: 0.001)

        guard case let .split(_, nestedRatio, _, _) = secondNode else {
            return XCTFail("Expected nested split")
        }
        // Nested ratio must be clamped against the 650pt allocated dimension (~0.5069)
        XCTAssertEqual(nestedRatio, 1.0 - (320.0 / 649.0), accuracy: 0.005)
        XCTAssertLessThanOrEqual(nestedRatio, 0.51)

        // Verify actual frame calculations from normalized tree match policy invariants
        let frames = normalizedTree.paneFrames(in: containerSize, policy: policy)
        guard let f1 = frames[p1], let f2 = frames[p2], let f3 = frames[p3] else {
            return XCTFail("Frames missing")
        }
        XCTAssertGreaterThanOrEqual(f1.width, policy.minimumLeafWidth - 0.01)
        XCTAssertGreaterThanOrEqual(f2.width, policy.minimumLeafWidth - 0.01)
        XCTAssertGreaterThanOrEqual(f3.width, policy.minimumLeafWidth - 0.01)
        XCTAssertEqual(f3.width, 320, accuracy: 0.1)
    }

    // MARK: - 16. Divider Dragging Drift & Reversal Invariance (CTO Review)

    /// Verifies the mathematical drag displacement formula used by divider dragging handlers.
    ///
    /// NOTE on Test Coverage Scope:
    /// - This test validates the displacement and ratio calculation arithmetic (`startDim + translation`)
    ///   against cumulative drift across repeated updates and direction reversals.
    /// - It tests model-level arithmetic and does NOT execute an AppKit/SwiftUI event loop or native `DragGesture`.
    /// - Actual interactive GUI behavior (touch/mouse tracking, pointer capture, and 120Hz display refresh)
    ///   remains explicitly UNVERIFIED pending production multi-pane UI integration in Stage P0-B.
    func testDividerDraggingPreventsCumulativeDriftAndHandlesReversals() {
        let p1 = PaneID()
        let p2 = PaneID()
        let policy = LayoutPolicy(
            minimumLeafWidth: 100,
            minimumLeafHeight: 100,
            dividerThickness: 1,
            maxPanes: 4
        )

        // Container available space: 1000 pt (divider 1 pt, container 1001 pt)
        let containerWidth: CGFloat = 1001
        let availableWidth: CGFloat = 1000
        let node1 = LayoutNode.leaf(p1)
        let node2 = LayoutNode.leaf(p2)

        // Initial state at drag start
        let initialRatio: Double = 0.5
        let initialFirstDim: CGFloat = availableWidth * CGFloat(initialRatio) // 500 pt

        // Simulated drag sequence with repeated onChanged events and direction reversals:
        // Cumulative translation offsets from gesture start:
        let simulatedTranslations: [CGFloat] = [
            10.0,   // drag right
            30.0,   // continue right
            75.0,   // continue right
            120.0,  // continue right
            60.0,   // direction reversal (drag left)
            10.0,   // continue left
            0.0,    // return to start point
            -50.0,  // drag left beyond start point
            -150.0, // continue left
            -50.0,  // direction reversal back right
            0.0     // return to start point
        ]

        for translation in simulatedTranslations {
            // Formula specified by CTO:
            // Compute movement strictly relative to the stable initial dimension captured at drag start
            let proposedFirstDim = initialFirstDim + translation
            let proposedRatio = Double(proposedFirstDim / availableWidth)
            let clamped = LayoutNode.clampedRatio(
                proposedRatio,
                axis: .horizontal,
                first: node1,
                second: node2,
                in: containerWidth,
                policy: policy
            )

            let expectedDim = min(max(500.0 + translation, 100.0), 900.0)
            let actualDim = availableWidth * CGFloat(clamped)
            XCTAssertEqual(
                actualDim,
                expectedDim,
                accuracy: 0.001,
                "Translation \(translation) must not exhibit cumulative drift"
            )
        }
    }

    // MARK: - 17. Property-Based Invariant Fuzzing

    func testParameterizedAndPropertyBasedFuzzing() throws {
        let policy = LayoutPolicy(
            minimumLeafWidth: 100,
            minimumLeafHeight: 100,
            dividerThickness: 2,
            maxPanes: 4
        )

        // Run 25 iterations of randomized layout operations
        for iteration in 0..<25 {
            var activePanes: [PaneID] = [PaneID()]
            var tree = WorkspaceLayoutTree(leaf: activePanes[0])

            let directions: [LayoutInsertionDirection] = [.left, .right, .top, .bottom]

            // Perform randomized insertions up to maxPanes
            let insertCount = Int.random(in: 1...3)
            for _ in 0..<insertCount {
                let newPane = PaneID()
                let target = activePanes.randomElement()!
                let dir = directions.randomElement()!
                let ratio = Double.random(in: 0.1...0.9)

                try tree.insert(newPane, adjacentTo: target, direction: dir, ratio: ratio, policy: policy)
                activePanes.append(newPane)
            }

            // Invariant 1: Pane count matches
            XCTAssertEqual(tree.paneCount, activePanes.count, "Iteration \(iteration)")
            XCTAssertEqual(Set(tree.leafIDs), Set(activePanes), "Iteration \(iteration)")

            // Test geometry with sufficient container size
            let containerWidth = CGFloat(activePanes.count) * 150 + 50
            let containerHeight = CGFloat(activePanes.count) * 150 + 50
            let container = CGRect(x: 10, y: 20, width: containerWidth, height: containerHeight)

            let frames = tree.paneFrames(in: container, policy: policy)
            XCTAssertEqual(frames.count, activePanes.count, "Iteration \(iteration)")

            // Invariant 2: No pane has negative or zero dimensions
            for (id, frame) in frames {
                XCTAssertGreaterThan(frame.width, 0, "Pane \(id) width > 0")
                XCTAssertGreaterThan(frame.height, 0, "Pane \(id) height > 0")
                XCTAssertTrue(container.contains(frame) || container.intersects(frame), "Pane inside container")
            }

            // Invariant 3: Pairwise disjoint (non-overlapping) panes
            let frameList = Array(frames.values)
            for i in 0..<frameList.count {
                for j in (i + 1)..<frameList.count {
                    let f1 = frameList[i]
                    let f2 = frameList[j]
                    let intersection = f1.intersection(f2)
                    XCTAssertTrue(
                        intersection.isNull || intersection.width <= 0.01 || intersection.height <= 0.01,
                        "Frames must not overlap in iteration \(iteration): \(f1) vs \(f2)"
                    )
                }
            }

            // Perform a removal if more than 1 pane
            if activePanes.count > 1 {
                let toRemove = activePanes.randomElement()!
                try tree.remove(toRemove)
                activePanes.removeAll(where: { $0 == toRemove })
                XCTAssertEqual(tree.paneCount, activePanes.count)
                XCTAssertFalse(tree.contains(toRemove))
            }
        }
    }
}
