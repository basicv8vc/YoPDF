import XCTest
@testable import YoPDFCore

final class CompanionBrowserSessionTests: XCTestCase {

    // MARK: - URL Normalization

    func testNormalizedURLAcceptsHTTPSAndHTTP() {
        XCTAssertEqual(
            CompanionBrowserLayoutPolicy.normalizedURL(from: "https://gemini.google.com/app")?.absoluteString,
            "https://gemini.google.com/app"
        )
        XCTAssertEqual(
            CompanionBrowserLayoutPolicy.normalizedURL(from: "  http://localhost:8080/docs  ")?.absoluteString,
            "http://localhost:8080/docs"
        )
    }

    func testNormalizedURLPrependsHTTPSForBareDomains() {
        XCTAssertEqual(
            CompanionBrowserLayoutPolicy.normalizedURL(from: "arxiv.org/abs/2401.00001")?.absoluteString,
            "https://arxiv.org/abs/2401.00001"
        )
        XCTAssertEqual(
            CompanionBrowserLayoutPolicy.normalizedURL(from: "localhost:3000")?.absoluteString,
            "http://localhost:3000"
        )
    }

    func testNormalizedURLTurnsPlainQueriesIntoSearchURL() {
        let url = CompanionBrowserLayoutPolicy.normalizedURL(from: "attention is all you need")
        XCTAssertEqual(url?.host, "www.google.com")
        XCTAssertEqual(url?.path, "/search")
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "q" })?.value, "attention is all you need")
    }

    func testNormalizedURLRejectsUnsafeSchemesAndEmptyInput() {
        XCTAssertNil(CompanionBrowserLayoutPolicy.normalizedURL(from: ""))
        XCTAssertNil(CompanionBrowserLayoutPolicy.normalizedURL(from: "   \n  "))
        XCTAssertNil(CompanionBrowserLayoutPolicy.normalizedURL(from: "javascript:alert(1)"))
        XCTAssertNil(CompanionBrowserLayoutPolicy.normalizedURL(from: "file:///etc/passwd"))
        XCTAssertNil(CompanionBrowserLayoutPolicy.normalizedURL(from: "data:text/html,<h1>hi</h1>"))
    }

    func testDisplayHostStripsWWWPrefix() {
        XCTAssertEqual(
            CompanionBrowserLayoutPolicy.displayHost(for: URL(string: "https://www.arxiv.org/abs/1234")),
            "arxiv.org"
        )
        XCTAssertEqual(
            CompanionBrowserLayoutPolicy.displayHost(for: URL(string: "https://gemini.google.com/app")),
            "gemini.google.com"
        )
    }

    // MARK: - Width Clamping

    func testClampedWidthEnforcesMinAndMaxRatio() {
        XCTAssertEqual(CompanionBrowserLayoutPolicy.clampedWidth(100, in: 1200), 320)
        XCTAssertEqual(CompanionBrowserLayoutPolicy.clampedWidth(900, in: 1200), 720)
        XCTAssertEqual(CompanionBrowserLayoutPolicy.clampedWidth(450, in: 1200), 450)
    }

    func testClampedWidthHandlesNarrowContainerGracefully() {
        XCTAssertEqual(CompanionBrowserLayoutPolicy.clampedWidth(420, in: 400), 240)
        XCTAssertEqual(CompanionBrowserLayoutPolicy.clampedWidth(.nan, in: 1000), 420)
    }

    // MARK: - Preset Matching

    func testPresetMatchingRecognizesBuiltInHosts() {
        XCTAssertEqual(
            CompanionBrowserPreset.matching(url: URL(string: "https://gemini.google.com/app/123")),
            .gemini
        )
        XCTAssertEqual(
            CompanionBrowserPreset.matching(url: URL(string: "https://chatgpt.com/c/abc")),
            .chatgpt
        )
        XCTAssertEqual(
            CompanionBrowserPreset.matching(url: URL(string: "https://claude.ai/new")),
            .claude
        )
        XCTAssertEqual(
            CompanionBrowserPreset.matching(url: URL(string: "https://arxiv.org/pdf/2301.00001")),
            .arxiv
        )
        XCTAssertNil(CompanionBrowserPreset.matching(url: URL(string: "https://example.com")))
    }

    // MARK: - Session Lazy Lifecycle & Memory Release

    @MainActor
    func testSessionIsLazyUntilFirstPresentAndSurvivesHideUntilReleased() {
        let suiteName = "app.yopdf.tests.companion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = CompanionBrowserSession(
            initialPreset: .gemini,
            userDefaults: defaults,
            usePersistentDataStore: false
        )

        XCTAssertFalse(session.isPresented)
        XCTAssertFalse(session.isWebViewLoaded)
        XCTAssertEqual(session.currentURL, CompanionBrowserPreset.gemini.url)

        session.present()
        XCTAssertTrue(session.isPresented)
        XCTAssertTrue(session.isWebViewLoaded)

        // Hiding preserves the warm WKWebView instance for instant reopen.
        session.hide()
        XCTAssertFalse(session.isPresented)
        XCTAssertTrue(session.isWebViewLoaded)

        // Releasing memory tears down the WKWebView instance.
        session.closeAndReleaseMemory()
        XCTAssertFalse(session.isPresented)
        XCTAssertFalse(session.isWebViewLoaded)
    }

    @MainActor
    func testSessionPersistsClampedPanelWidth() {
        let suiteName = "app.yopdf.tests.companion.width.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = CompanionBrowserSession(
            userDefaults: defaults,
            usePersistentDataStore: false
        )
        session.updatePanelWidth(510, containerWidth: 1200)
        XCTAssertEqual(session.panelWidth, 510)

        let reloaded = CompanionBrowserSession(
            userDefaults: defaults,
            usePersistentDataStore: false
        )
        XCTAssertEqual(reloaded.panelWidth, 510)
    }

    @MainActor
    func testSessionRejectsUnsafeNavigationInput() {
        let suiteName = "app.yopdf.tests.companion.nav.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = CompanionBrowserSession(
            userDefaults: defaults,
            usePersistentDataStore: false
        )
        XCTAssertFalse(session.navigate(toInput: "javascript:alert(1)"))
        XCTAssertFalse(session.isWebViewLoaded)
        XCTAssertEqual(session.currentURL, CompanionBrowserPreset.gemini.url)
    }
}
