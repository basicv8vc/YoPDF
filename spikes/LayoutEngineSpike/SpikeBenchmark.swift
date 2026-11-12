//
//  SpikeBenchmark.swift
//  spikes/LayoutEngineSpike
//
//  Empirical Benchmark Harness for Layout Engine Spike (Pure SwiftUI vs AppKit NSSplitViewController).
//  Created for Task P0-B-A.
//

import Foundation
import CoreGraphics

@main
struct BenchmarkMain {
    static func main() {
        print("=================================================================")
        print(" YoPDF Layout Engine Spike - Empirical Benchmark & Evaluation")
        print(" Target Platform: macOS Sonoma+ (Darwin arm64)")
        print(" Host Architecture: Apple Silicon")
        print("=================================================================")

        let iterations = 10_000
        print("\n[Benchmark 1] Recursive Geometry Calculation Throughput (10,000 frames)")

        let policy = LayoutPolicy(
            minimumLeafWidth: 320,
            minimumLeafHeight: 240,
            dividerThickness: 1,
            maxPanes: 4
        )

        // 3-level nested tree: P1 | (P2 / (P4 | P3))
        let p1 = PaneID()
        let p2 = PaneID()
        let p3 = PaneID()
        let p4 = PaneID()

        let threeLevelTree = WorkspaceLayoutTree(
            root: .split(
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(p1),
                second: .split(
                    axis: .vertical,
                    ratio: 0.5,
                    first: .leaf(p2),
                    second: .split(
                        axis: .horizontal,
                        ratio: 0.5,
                        first: .leaf(p4),
                        second: .leaf(p3)
                    )
                )
            )
        )

        // Generate deterministic indexed input sizes
        var sizes: [CGSize] = []
        sizes.reserveCapacity(iterations)
        for i in 0..<iterations {
            let w = 800.0 + Double(i % 1200)
            let h = 600.0 + Double(i % 800)
            sizes.append(CGSize(width: w, height: h))
        }

        // Warm-up phase (1,000 iterations, not timed)
        var warmUpChecksum: Double = 0.0
        for i in 0..<1_000 {
            let s = sizes[i % sizes.count]
            let frames = threeLevelTree.paneFrames(in: s, policy: policy)
            for frame in frames.values {
                warmUpChecksum += Double(frame.width)
            }
        }
        _ = warmUpChecksum

        // Timed measurement loop: deterministic indexed access, zero random generation
        var geometryChecksum: Double = 0.0
        let start = DispatchTime.now()
        for i in 0..<iterations {
            let s = sizes[i]
            let frames = threeLevelTree.paneFrames(in: s, policy: policy)
            for frame in frames.values {
                geometryChecksum += Double(frame.minX + frame.minY + frame.width + frame.height)
            }
        }
        let end = DispatchTime.now()
        let nano = Double(end.uptimeNanoseconds - start.uptimeNanoseconds)
        let totalSeconds = nano / 1_000_000_000.0
        let averageMicroseconds = (nano / Double(iterations)) / 1_000.0

        print("  - Total time for \(iterations) frames: \(String(format: "%.4f", totalSeconds))s")
        print("  - Average computation per frame: \(String(format: "%.2f", averageMicroseconds)) µs")
        let achievableEvals = 1_000_000.0 / averageMicroseconds
        print("  - Model geometry throughput: \(String(format: "%.0f", achievableEvals)) evaluations/sec (Model computation only; UI frame rate depends on view hierarchy)")
        print("  - Accumulated geometry checksum: \(String(format: "%.2f", geometryChecksum)) (verifies observable consumption)")

        // Benchmark 2: Dynamic Ratio Clamping Invariant Verification
        print("\n[Benchmark 2] Dynamic Ratio Clamping Invariant Verification")
        var violations = 0

        @inline(__always)
        func validateFrame(_ frame: CGRect, policy: LayoutPolicy) -> Bool {
            guard frame.origin.x.isFinite,
                  frame.origin.y.isFinite,
                  frame.size.width.isFinite,
                  frame.size.height.isFinite else {
                return false
            }
            guard frame.width >= policy.minimumLeafWidth - 0.01,
                  frame.height >= policy.minimumLeafHeight - 0.01 else {
                return false
            }
            return true
        }

        // Suite 2A: Horizontal Split Stress Test (1,000 deterministic iterations, expected count: 2)
        for i in 0..<1_000 {
            let width = 641.0 + Double(i % 1359)
            let height = 500.0 + Double(i % 500)
            let ratio: Double
            if i % 100 == 0 {
                ratio = .nan
            } else if i % 100 == 1 {
                ratio = .infinity
            } else if i % 100 == 2 {
                ratio = -.infinity
            } else {
                ratio = -1.0 + Double(i % 300) / 100.0 // from -1.0 to +2.0
            }

            let tree = WorkspaceLayoutTree(
                root: .split(
                    axis: .horizontal,
                    ratio: ratio,
                    first: .leaf(p1),
                    second: .leaf(p2)
                )
            )
            let frames = tree.paneFrames(in: CGSize(width: width, height: height), policy: policy)
            if frames.count != 2 {
                violations += 1
            }
            for (_, frame) in frames {
                if !validateFrame(frame, policy: policy) {
                    violations += 1
                }
            }
        }

        // Suite 2B: Vertical Split Stress Test (1,000 deterministic iterations, expected count: 2)
        for i in 0..<1_000 {
            let width = 600.0 + Double(i % 600)
            let height = 481.0 + Double(i % 1319)
            let ratio: Double
            if i % 100 == 0 {
                ratio = .nan
            } else if i % 100 == 1 {
                ratio = .infinity
            } else if i % 100 == 2 {
                ratio = -.infinity
            } else {
                ratio = -1.0 + Double(i % 300) / 100.0 // from -1.0 to +2.0
            }

            let tree = WorkspaceLayoutTree(
                root: .split(
                    axis: .vertical,
                    ratio: ratio,
                    first: .leaf(p1),
                    second: .leaf(p2)
                )
            )
            let frames = tree.paneFrames(in: CGSize(width: width, height: height), policy: policy)
            if frames.count != 2 {
                violations += 1
            }
            for (_, frame) in frames {
                if !validateFrame(frame, policy: policy) {
                    violations += 1
                }
            }
        }

        // Suite 2C: Asymmetric Nested Split Stress Test (1,000 deterministic iterations, expected count: 3)
        // first: P1 (min width 320, min height 240)
        // second: (P2 | P3) (min width 320 + 1 + 320 = 641, min height 240)
        // Total minimum width: 320 + 1 + 641 = 962 pt
        for i in 0..<1_000 {
            let width = 962.0 + Double(i % 1538) // 962 to 2500 pt
            let height = 500.0 + Double(i % 500)
            let rootRatio: Double
            if i % 100 == 0 {
                rootRatio = .nan
            } else if i % 100 == 1 {
                rootRatio = .infinity
            } else if i % 100 == 2 {
                rootRatio = -.infinity
            } else {
                rootRatio = -1.0 + Double(i % 300) / 100.0
            }

            let nestedRatio = -0.5 + Double((i * 7) % 201) / 100.0
            let tree = WorkspaceLayoutTree(
                root: .split(
                    axis: .horizontal,
                    ratio: rootRatio,
                    first: .leaf(p1),
                    second: .split(
                        axis: .horizontal,
                        ratio: nestedRatio,
                        first: .leaf(p2),
                        second: .leaf(p3)
                    )
                )
            )
            let frames = tree.paneFrames(in: CGSize(width: width, height: height), policy: policy)
            if frames.count != 3 {
                violations += 1
            }
            for (_, frame) in frames {
                if !validateFrame(frame, policy: policy) {
                    violations += 1
                }
            }
        }

        print("  - Stress test suites: 3 (Horizontal [2 panes], Vertical [2 panes], Asymmetric Nested [3 panes])")
        print("  - Total stress iterations: 3,000")
        print("  - Invariants checked per frame: isFinite(x,y,w,h), minWidth, minHeight, paneCount")
        print("  - Constraint violations: \(violations)")
        if violations > 0 {
            print("  - Status: FAILED (\(violations) violations detected)")
            exit(1)
        } else {
            print("  - Status: PASSED (100% Invariant Satisfaction across all suites)")
        }

        // Benchmark 3: Tree Serialization & Deserialization
        print("\n[Benchmark 3] Tree Serialization & Deserialization Overhead")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try! encoder.encode(threeLevelTree)
        let decodeIterations = 1_000

        // Warm-up phase (100 iterations, not timed)
        var warmUpDecodeChecksum = 0
        for _ in 0..<100 {
            let tree = try! decoder.decode(WorkspaceLayoutTree.self, from: data)
            warmUpDecodeChecksum += tree.paneCount
        }
        _ = warmUpDecodeChecksum

        // Timed measurement loop
        var decodeChecksum = 0
        let decodeStart = DispatchTime.now()
        for _ in 0..<decodeIterations {
            let tree = try! decoder.decode(WorkspaceLayoutTree.self, from: data)
            decodeChecksum += tree.paneCount + tree.leafIDs.count
        }
        let decodeEnd = DispatchTime.now()
        let decodeNano = Double(decodeEnd.uptimeNanoseconds - decodeStart.uptimeNanoseconds)
        let decodeTotalSeconds = decodeNano / 1_000_000_000.0
        let decodeAverageMicroseconds = (decodeNano / Double(decodeIterations)) / 1_000.0

        print("  - JSON payload size: \(data.count) bytes")
        print("  - Total time for \(decodeIterations) decodes: \(String(format: "%.4f", decodeTotalSeconds))s")
        print("  - Average decode latency: \(String(format: "%.2f", decodeAverageMicroseconds)) µs")
        print("  - Accumulated decode checksum: \(decodeChecksum) (verifies observable consumption)")

        print("\n=================================================================")
        print(" Benchmark Completed Successfully.")
        print("=================================================================")
    }
}
