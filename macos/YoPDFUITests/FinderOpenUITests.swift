import AppKit
import XCTest

@MainActor
final class FinderOpenUITests: XCTestCase {

    func testFinderOpenFromColdLaunchThenExistingAndClosedWindows() async throws {
        let first = try PDFFixtureFactory.writeTemporaryPDF(named: "finder-first")
        let second = try PDFFixtureFactory.writeTemporaryPDF(named: "finder-second")
        let corrupt = try PDFFixtureFactory.writeTemporaryFile(
            named: "finder-corrupt.pdf", contents: Data("Not a PDF".utf8)
        )
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: corrupt.deletingLastPathComponent())
        }

        let applicationURL = try applicationURL()
        let callbackTrace = FileManager.default.temporaryDirectory
            .appendingPathComponent("yopdf-open-callbacks-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: callbackTrace) }
        let app = XCUIApplication(url: applicationURL)
        defer { app.terminate() }
        app.terminate()

        // LaunchServices sends the same open-document event as Finder's Open
        // With command. Do not use the screenshot hook or the in-app Open panel.
        try await open([first], with: applicationURL, callbackTrace: callbackTrace)
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].waitForExistence(timeout: 10),
                      "A cold Finder launch must load the requested PDF, not just start the app.")
        let coldCallbacks = try await callbacksAfterSettling(in: callbackTrace)
        XCTAssertEqual(coldCallbacks.count, 1, "One Finder action must have one file-open callback.")
        XCTAssertEqual(coldCallbacks.first?.paths, [first.path])
        XCTAssertTrue(coldCallbacks.first?.source.hasPrefix("AppKit.") == true,
                      "File opens must have one authoritative AppKit entry point.")

        // LaunchServices receives the two files as one batch. YoPDF currently
        // declines multi-file batches; it must leave the existing document
        // alone rather than opening only the last item.
        try clear(callbackTrace)
        try await open(
            [first, second],
            with: applicationURL,
            callbackTrace: callbackTrace,
            allowLaunchServicesFailure: true
        )
        let batchCallbacks = try await callbacksAfterSettling(in: callbackTrace)
        XCTAssertEqual(batchCallbacks.count, 1)
        XCTAssertTrue(batchCallbacks.first?.source.hasPrefix("AppKit.") == true)
        XCTAssertEqual(batchCallbacks.first?.paths, [first.path, second.path])
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].exists)
        XCTAssertFalse(app.staticTexts[second.lastPathComponent].exists,
                       "A rejected batch must not silently keep only its last PDF.")

        try clear(callbackTrace)
        try await open([second], with: applicationURL, callbackTrace: callbackTrace)
        XCTAssertTrue(app.staticTexts[second.lastPathComponent].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].exists,
                      "Opening another PDF must leave the first reader open.")
        XCTAssertEqual(app.windows.count, 2, "A warm file open should create a second reader.")
        let warmCallbacks = try await callbacksAfterSettling(in: callbackTrace)
        XCTAssertEqual(warmCallbacks.count, 1, "Warm open must not be delivered twice.")
        XCTAssertEqual(warmCallbacks.first?.paths, [second.path])

        app.typeKey("w", modifierFlags: .command)
        XCTAssertEqual(app.windows.count, 1, "Closing the new reader must leave the first reader open.")
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 5))
        try clear(callbackTrace)
        try await open([first], with: applicationURL, callbackTrace: callbackTrace)
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].waitForExistence(timeout: 10),
                      "Finder must create a reader after every reader window was closed.")
        XCTAssertEqual(app.windows.count, 1)

        try clear(callbackTrace)
        try await open([corrupt], with: applicationURL, callbackTrace: callbackTrace)
        XCTAssertTrue(app.staticTexts["Couldn’t open this document"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].exists,
                      "An unreadable Finder file must leave the current PDF open.")
        app.typeKey(.return, modifierFlags: [])
        try clear(callbackTrace)
        try await open([second], with: applicationURL, callbackTrace: callbackTrace)
        XCTAssertTrue(app.staticTexts[second.lastPathComponent].waitForExistence(timeout: 10),
                      "A failed open must release the request slot for the next Finder event.")
    }

    private func applicationURL() throws -> URL {
        // The UI test bundle lives inside the runner app beside YoPDF.app in
        // BUILT_PRODUCTS_DIR. Resolve that exact build, not a LaunchServices
        // bundle-ID lookup that could choose another installed YoPDF.
        var directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("YoPDF.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "FinderOpenUITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not find YoPDF.app beside the test runner."
        ])
    }

    private func clear(_ trace: URL) throws {
        try Data().write(to: trace, options: .atomic)
    }

    private func callbacksAfterSettling(in trace: URL) async throws -> [OpenCallback] {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let callbacks = try recordedCallbacks(in: trace)
            if !callbacks.isEmpty {
                try await Task.sleep(for: .milliseconds(500))
                return try recordedCallbacks(in: trace)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("LaunchServices did not produce a file-open callback. Trace: \(trace.path)")
        return try recordedCallbacks(in: trace)
    }

    private func recordedCallbacks(in trace: URL) throws -> [OpenCallback] {
        guard let data = try? Data(contentsOf: trace) else { return [] }
        return try String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(OpenCallback.self, from: Data($0.utf8)) }
    }

    private func open(
        _ urls: [URL],
        with applicationURL: URL,
        callbackTrace: URL,
        allowLaunchServicesFailure: Bool = false
    ) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--yopdf-open-trace=\(callbackTrace.path)"
        ]
        do {
            _ = try await NSWorkspace.shared.open(
                urls, withApplicationAt: applicationURL, configuration: configuration
            )
        } catch {
            guard allowLaunchServicesFailure else { throw error }
        }
    }

    private struct OpenCallback: Decodable {
        let source: String
        let paths: [String]
    }
}
