import XCTest
@testable import YoPDFCore

/// Large-file behaviour: hashing must stream instead of allocating the file,
/// and the save path must stay correct when the file is much bigger than a
/// fixture.
///
/// The 200 MB case is the acceptance target. It needs about 400 MB of free
/// space for the file plus its staging copy, so it skips (loudly) on a machine
/// without that headroom; the 32 MB case always runs and checks the same
/// properties at a size that fits.
final class DocumentStoreScaleTests: XCTestCase {

    private static let mebibyte = 1024 * 1024

    func testTwoHundredMegabyteFileIsHashedInConstantMemoryAndSavedCorrectly() throws {
        let available = try availableCapacity()
        try XCTSkipIf(
            available < 800 * 1024 * 1024,
            "needs about 800 MB free for a 200 MB file plus staging; \(available / 1024 / 1024) MB available"
        )
        try runScaleTest(size: 200 * Self.mebibyte, label: "200 MB")
    }

    /// Same assertions at a size that fits on a nearly full disk, so the
    /// streaming property is still verified on every run.
    func testStreamingBehaviourAtAvailableSize() throws {
        let available = try availableCapacity()
        try XCTSkipIf(available < 128 * 1024 * 1024, "not enough free space for a 32 MB file")
        try runScaleTest(size: 32 * Self.mebibyte, label: "32 MB")
    }

    // MARK: - The shared scenario

    private func runScaleTest(size: Int, label: String) throws {
        let directory = try TemporaryDirectory("scale")
        defer { directory.remove() }

        let url = directory.url.appendingPathComponent("large.pdf")
        try Self.writeLargeFile(to: url, size: size)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
            size
        )

        let store = DocumentStore()
        let io = SystemDocumentStoreIO()
        // Warm up allocator and file caches so the measurement reflects the
        // hashing path, not first-touch overhead.
        _ = try io.version(of: url)

        let heapBefore = heapBytesInUse()
        let footprintBefore = physicalFootprint()
        let openStarted = Date()
        let session = try store.open(url)
        let openDuration = Date().timeIntervalSince(openStarted)
        let heapAfter = heapBytesInUse()
        let footprintAfter = physicalFootprint()
        defer { session.close() }

        let heapGrowth = heapAfter > heapBefore ? heapAfter - heapBefore : 0
        let footprintGrowth = footprintAfter > footprintBefore ? footprintAfter - footprintBefore : 0
        print(
            "[scale] \(label): open+hash \(String(format: "%.2f", openDuration))s, "
                + "heap growth \(heapGrowth / 1024) KB, footprint growth \(footprintGrowth / 1024 / 1024) MB"
        )
        // Streaming keeps the heap at chunk size; loading the file would show
        // growth close to the file size.
        XCTAssertLessThan(
            heapGrowth,
            16 * 1024 * 1024,
            "hashing must stream: a \(label) file must not be allocated in memory"
        )
        XCTAssertEqual(session.version.size, Int64(size))

        // Replace the whole file: the save path has to stay correct at scale.
        let updated = try Self.makeLargePayload(size: size + 1, seed: 0x5A)
        let saveStarted = Date()
        try session.save(updated)
        let saveDuration = Date().timeIntervalSince(saveStarted)
        print("[scale] \(label): save \(String(format: "%.2f", saveDuration))s")

        XCTAssertEqual(session.version.size, Int64(size + 1))
        XCTAssertEqual(
            session.version.contentHash,
            TestPayload.sha256(updated),
            "the file on disk must be exactly what was saved"
        )

        // Spot-check the tail without reading the whole file back.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(size - 16))
        let tail = try handle.read(upToCount: 17) ?? Data()
        XCTAssertEqual(tail, updated.suffix(17))
        XCTAssertEqual(directory.stagingLeftovers(), [])
    }

    /// Bytes available without purging anything else, which is the number that
    /// matters before writing a large temporary file.
    private func availableCapacity() throws -> Int64 {
        let directory = FileManager.default.temporaryDirectory
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values.volumeAvailableCapacity ?? 0)
    }

    // MARK: - Fixtures

    private static func makeLargePayload(size: Int, seed: UInt8 = 0x41) throws -> Data {
        var data = Data()
        data.reserveCapacity(size)
        var remaining = size
        var index = 0
        while remaining > 0 {
            let chunk = min(remaining, mebibyte)
            data.append(block(index: index, size: chunk, seed: seed))
            remaining -= chunk
            index += 1
        }
        return data
    }

    private static func writeLargeFile(to url: URL, size: Int) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var remaining = size
        var index = 0
        while remaining > 0 {
            let chunk = min(remaining, mebibyte)
            try handle.write(contentsOf: block(index: index, size: chunk, seed: 0x31))
            remaining -= chunk
            index += 1
        }
        try handle.synchronize()
    }

    /// A distinct block per index, built with a bulk fill instead of a
    /// per-byte closure: a 200 MB fixture should not take a minute in Debug.
    private static func block(index: Int, size: Int, seed: UInt8) -> Data {
        let fill = UInt8((index &* 31 &+ Int(seed)) % 251)
        var data = Data(repeating: fill, count: size)
        let stamp = UInt64(index) &* 0x9E37_79B9 &+ UInt64(seed)
        var state = stamp | 1
        for offset in 0..<min(64, size) {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            data[offset] = UInt8((state >> 33) & 0xFF)
        }
        return data
    }
}
