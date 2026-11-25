import AppKit
import Combine
import Foundation
import WebKit

/// Built-in quick destinations for the companion reading browser.
enum CompanionBrowserPreset: String, CaseIterable, Identifiable, Sendable {
    case gemini
    case chatgpt
    case claude
    case scholar
    case arxiv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini: return "Gemini"
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .scholar: return "Google Scholar"
        case .arxiv: return "arXiv"
        }
    }

    var systemImage: String {
        switch self {
        case .gemini: return "sparkles"
        case .chatgpt: return "bubble.left.and.bubble.right"
        case .claude: return "text.bubble"
        case .scholar: return "graduationcap"
        case .arxiv: return "doc.text.magnifyingglass"
        }
    }

    var url: URL {
        switch self {
        case .gemini: return URL(string: "https://gemini.google.com/app")!
        case .chatgpt: return URL(string: "https://chatgpt.com")!
        case .claude: return URL(string: "https://claude.ai")!
        case .scholar: return URL(string: "https://scholar.google.com")!
        case .arxiv: return URL(string: "https://arxiv.org")!
        }
    }

    static func matching(url: URL?) -> CompanionBrowserPreset? {
        guard let host = url?.host?.lowercased() else { return nil }
        if host.contains("gemini.google.com") { return .gemini }
        if host.contains("chatgpt.com") || host.contains("chat.openai.com") { return .chatgpt }
        if host.contains("claude.ai") { return .claude }
        if host.contains("scholar.google.") { return .scholar }
        if host.contains("arxiv.org") { return .arxiv }
        return nil
    }
}

/// Pure helpers for URL normalization, display formatting, and drawer width clamping.
enum CompanionBrowserLayoutPolicy: Sendable {
    static let defaultWidth: CGFloat = 420
    static let minimumWidth: CGFloat = 320
    static let maximumWidthRatio: CGFloat = 0.60
    static let widthDefaultsKey = "YoPDFCompanionBrowserWidth.v1"

    /// Clamps a proposed drawer width against the available window width so the
    /// PDF reader always retains usable space.
    static func clampedWidth(_ proposed: CGFloat, in containerWidth: CGFloat) -> CGFloat {
        guard containerWidth.isFinite, containerWidth > 0 else {
            return max(minimumWidth, proposed.isFinite ? proposed : defaultWidth)
        }
        let maxAllowed = max(180, floor(containerWidth * maximumWidthRatio))
        let minAllowed = min(minimumWidth, maxAllowed)
        let candidate = proposed.isFinite ? proposed : defaultWidth
        return min(max(candidate, minAllowed), maxAllowed)
    }

    /// Returns the horizontal width remaining for the main reader pane alongside
    /// the companion browser drawer so wide toolbars in the reader column cannot
    /// push the companion panel past the trailing edge of the window.
    static func readerWidth(
        in containerWidth: CGFloat,
        panelWidth: CGFloat,
        isPresented: Bool
    ) -> CGFloat {
        guard containerWidth.isFinite, containerWidth > 0 else { return 0 }
        guard isPresented else { return containerWidth }
        let companionWidth = clampedWidth(panelWidth, in: containerWidth)
        return max(0, containerWidth - companionWidth)
    }

    /// Normalizes user-entered URL or search text into a safe HTTP(S) URL.
    /// Rejects non-HTTP(S) schemes such as `file:`, `javascript:`, or `data:`.
    static func normalizedURL(from rawInput: String) -> URL? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let range = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<range.lowerBound]).lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
                return nil
            }
            return url
        }

        // Reject explicit dangerous schemes without "://", e.g. "javascript:alert(1)".
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let prefix = trimmed[..<colonIndex].lowercased()
            let isLikelyPort = trimmed[trimmed.index(after: colonIndex)...].first?.isNumber == true
            if !isLikelyPort, !prefix.contains("."), !prefix.contains("/") {
                return nil
            }
        }

        let containsWhitespace = trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
        let lower = trimmed.lowercased()
        let looksLikeHost = !containsWhitespace && (
            trimmed.contains(".") ||
            lower == "localhost" ||
            lower.hasPrefix("localhost:") ||
            lower.hasPrefix("localhost/")
        )

        if looksLikeHost {
            let scheme = (lower == "localhost" || lower.hasPrefix("localhost:") || lower.hasPrefix("localhost/"))
                ? "http://"
                : "https://"
            guard let url = URL(string: scheme + trimmed), let host = url.host, !host.isEmpty else {
                return nil
            }
            return url
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    static func displayHost(for url: URL?) -> String {
        guard let url else { return "" }
        if let host = url.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return url.absoluteString
    }
}

/// Owns one window's lightweight companion `WKWebView` session.
///
/// The `WKWebView` is created lazily only when the user first opens the panel,
/// so normal offline PDF reading incurs zero WebKit process overhead. Closing
/// the panel keeps the instance alive for instant resume; `closeAndReleaseMemory()`
/// tears down the WebView and its WebContent process on demand.
@MainActor
final class CompanionBrowserSession: NSObject, ObservableObject {

    /// Deterministic UUID for macOS 14+ persistent `WKWebsiteDataStore(forIdentifier:)`.
    /// Keeps Google/Gemini login cookies persistent across launches while isolated to YoPDF.
    private static let persistentDataStoreID = UUID(uuidString: "9D3E6A41-6C74-4E53-9B3C-6F1A4B2E8C10")!

    /// Standard macOS Desktop Safari user agent so Google OAuth and Gemini render
    /// with full desktop support rather than blocking an unrecognized embedded WebView.
    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    @Published var isPresented: Bool = false
    @Published var panelWidth: CGFloat
    @Published private(set) var currentURL: URL
    @Published var addressText: String
    @Published private(set) var pageTitle: String
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var estimatedProgress: Double = 0
    @Published private(set) var isWebViewLoaded: Bool = false
    @Published private(set) var selectionToastMessage: String? = nil

    private let userDefaults: UserDefaults
    private let usePersistentDataStore: Bool
    private var backingWebView: WKWebView?
    private var kvoObservations: [NSKeyValueObservation] = []
    private var popupWindows: [ObjectIdentifier: NSWindow] = [:]
    private var toastDismissTask: Task<Void, Never>?

    var activePreset: CompanionBrowserPreset? {
        CompanionBrowserPreset.matching(url: currentURL)
    }

    init(
        initialPreset: CompanionBrowserPreset = .gemini,
        userDefaults: UserDefaults = .standard,
        usePersistentDataStore: Bool = true
    ) {
        self.userDefaults = userDefaults
        self.usePersistentDataStore = usePersistentDataStore
        let storedWidth = userDefaults.double(forKey: CompanionBrowserLayoutPolicy.widthDefaultsKey)
        self.panelWidth = storedWidth > 0 ? CGFloat(storedWidth) : CompanionBrowserLayoutPolicy.defaultWidth
        self.currentURL = initialPreset.url
        self.addressText = initialPreset.url.absoluteString
        self.pageTitle = initialPreset.title
        super.init()
    }

    deinit {
        toastDismissTask?.cancel()
    }

    // MARK: - Presentation & Lifecycle

    func toggle() {
        if isPresented {
            hide()
        } else {
            present()
        }
    }

    func present() {
        isPresented = true
        _ = ensureWebView()
    }

    /// Hides the drawer while keeping the live `WKWebView` warm so reopening
    /// resumes an active Gemini conversation instantaneously.
    func hide() {
        isPresented = false
    }

    /// Hides the drawer and destroys the underlying `WKWebView` to reclaim
    /// WebContent process memory.
    func closeAndReleaseMemory() {
        isPresented = false
        toastDismissTask?.cancel()
        selectionToastMessage = nil
        closeAllPopups()

        kvoObservations.removeAll()
        if let webView = backingWebView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
        }
        backingWebView = nil
        isWebViewLoaded = false
        canGoBack = false
        canGoForward = false
        isLoading = false
        estimatedProgress = 0
    }

    func updatePanelWidth(_ width: CGFloat, containerWidth: CGFloat) {
        let clamped = CompanionBrowserLayoutPolicy.clampedWidth(width, in: containerWidth)
        panelWidth = clamped
        userDefaults.set(Double(clamped), forKey: CompanionBrowserLayoutPolicy.widthDefaultsKey)
    }

    // MARK: - Navigation

    func selectPreset(_ preset: CompanionBrowserPreset) {
        currentURL = preset.url
        addressText = preset.url.absoluteString
        pageTitle = preset.title
        if isPresented || isWebViewLoaded {
            ensureWebView().load(URLRequest(url: preset.url))
        }
    }

    @discardableResult
    func navigate(toInput rawInput: String) -> Bool {
        guard let url = CompanionBrowserLayoutPolicy.normalizedURL(from: rawInput) else {
            return false
        }
        currentURL = url
        addressText = url.absoluteString
        let webView = ensureWebView()
        webView.load(URLRequest(url: url))
        return true
    }

    func goBack() {
        backingWebView?.goBack()
    }

    func goForward() {
        backingWebView?.goForward()
    }

    func reloadOrStop() {
        guard let webView = backingWebView else {
            _ = ensureWebView()
            return
        }
        if isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    func openInExternalBrowser() {
        NSWorkspace.shared.open(currentURL)
    }

    /// Copies user-selected PDF text to the pasteboard, reveals the companion panel,
    /// and focuses the web view so the user can press ⌘V immediately.
    func sendSelectedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)

        present()
        focusWebView()

        toastDismissTask?.cancel()
        selectionToastMessage = "Selection copied — press ⌘V to paste"
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.selectionToastMessage = nil
        }
    }

    func focusWebView() {
        guard let webView = backingWebView, let window = webView.window else { return }
        window.makeFirstResponder(webView)
    }

    // MARK: - Lazy WKWebView Creation

    func ensureWebView() -> WKWebView {
        if let existing = backingWebView {
            return existing
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = usePersistentDataStore
            ? WKWebsiteDataStore(forIdentifier: Self.persistentDataStoreID)
            : .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.safariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        backingWebView = webView
        isWebViewLoaded = true
        installObservations(on: webView)
        webView.load(URLRequest(url: currentURL))
        return webView
    }

    private func installObservations(on webView: WKWebView) {
        kvoObservations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                let newURL = view.url
                Task { @MainActor [weak self] in
                    guard let self, let newURL else { return }
                    self.currentURL = newURL
                    self.addressText = newURL.absoluteString
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                let newTitle = view.title
                Task { @MainActor [weak self] in
                    guard let self, let newTitle, !newTitle.isEmpty else { return }
                    self.pageTitle = newTitle
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                let value = view.canGoBack
                Task { @MainActor [weak self] in
                    self?.canGoBack = value
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                let value = view.canGoForward
                Task { @MainActor [weak self] in
                    self?.canGoForward = value
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                let value = view.isLoading
                Task { @MainActor [weak self] in
                    self?.isLoading = value
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                let value = view.estimatedProgress
                Task { @MainActor [weak self] in
                    self?.estimatedProgress = value
                }
            }
        ]
    }

    private func closeAllPopups() {
        let windows = Array(popupWindows.values)
        popupWindows.removeAll()
        for window in windows {
            window.close()
        }
    }
}

// MARK: - WKNavigationDelegate & WKUIDelegate

extension CompanionBrowserSession: WKNavigationDelegate, WKUIDelegate {

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Open OAuth / popup windows in a lightweight child window sharing the same
        // WKWebViewConfiguration so `window.opener` and Google Sign-In complete cleanly.
        if navigationAction.targetFrame == nil {
            let isLikelyPopup = (windowFeatures.width != nil || windowFeatures.height != nil)
                || (navigationAction.request.url?.host?.contains("accounts.google.com") == true)

            if isLikelyPopup {
                let popupWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
                popupWebView.customUserAgent = Self.safariUserAgent
                popupWebView.uiDelegate = self
                popupWebView.navigationDelegate = self

                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                    styleMask: [.titled, .closable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "Sign In"
                window.contentView = popupWebView
                window.isReleasedWhenClosed = false
                window.center()
                window.makeKeyAndOrderFront(nil)

                popupWindows[ObjectIdentifier(popupWebView)] = window
                return popupWebView
            }

            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        if let window = popupWindows.removeValue(forKey: key) {
            window.close()
        }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection

        if let window = webView.window {
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        } else {
            let response = panel.runModal()
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
}
