import Foundation
import XCTest
@testable import YoPDFCore

final class RecentDocumentThumbnailCachePolicyTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    func testStampIsStableForUnchangedFileState() {
        let first = RecentDocumentThumbnailCachePolicy.stamp(
            modificationDate: epoch, fileSize: 4_096
        )
        let second = RecentDocumentThumbnailCachePolicy.stamp(
            modificationDate: epoch, fileSize: 4_096
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            RecentDocumentThumbnailCachePolicy.fileName(stamp: first),
            "\(first).png"
        )
    }

    func testStampChangesWhenFileChanges() {
        let original = RecentDocumentThumbnailCachePolicy.stamp(
            modificationDate: epoch, fileSize: 4_096
        )
        let edited = RecentDocumentThumbnailCachePolicy.stamp(
            modificationDate: epoch.addingTimeInterval(60), fileSize: 4_096
        )
        let resized = RecentDocumentThumbnailCachePolicy.stamp(
            modificationDate: epoch, fileSize: 8_192
        )
        XCTAssertNotEqual(original, edited)
        XCTAssertNotEqual(original, resized)
    }

    func testMissingAttributesFallBackToWeakStamp() {
        let weak = RecentDocumentThumbnailCachePolicy.stamp(
            modificationDate: nil, fileSize: nil
        )
        let dated = RecentDocumentThumbnailCachePolicy.stamp(
            modificationDate: epoch, fileSize: 4_096
        )
        XCTAssertEqual(weak, "unknown")
        XCTAssertNotEqual(weak, dated)
    }

    func testDirectoryNameIsTheItemIdentifier() {
        let id = UUID()
        XCTAssertEqual(
            RecentDocumentThumbnailCachePolicy.directoryName(for: id),
            id.uuidString
        )
    }

    func testStaleDirectoriesReportsOnlyUnusedSubdirectories() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "YoPDFCachePolicyTests-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let kept = UUID()
        let removed = UUID()
        for id in [kept, removed] {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(id.uuidString, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try fileManager.createDirectory(
            at: root.appendingPathComponent("orphan", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("note".utf8).write(to: root.appendingPathComponent("notes.txt"))

        let stale = RecentDocumentThumbnailCachePolicy.staleDirectories(
            in: root, keeping: [kept], fileManager: fileManager
        )
        XCTAssertEqual(
            Set(stale.map(\.lastPathComponent)),
            Set([removed.uuidString, "orphan"])
        )
    }

    func testMissingCacheDirectoryProducesNoStaleEntries() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(
            "YoPDFCachePolicyMissing-\(UUID().uuidString)", isDirectory: true
        )
        XCTAssertTrue(
            RecentDocumentThumbnailCachePolicy.staleDirectories(
                in: missing, keeping: []
            ).isEmpty
        )
    }
}
