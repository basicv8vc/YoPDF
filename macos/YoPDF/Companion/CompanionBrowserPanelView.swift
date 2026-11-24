import AppKit
import SwiftUI
import WebKit

/// Four-point Gemini-inspired sparkle shape for the top-right pill button.
private struct GeminiSparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        let cy = rect.midY
        let inner = min(w, h) * 0.16

        var path = Path()
        path.move(to: CGPoint(x: cx, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: cy), control: CGPoint(x: cx + inner, y: cy - inner))
        path.addQuadCurve(to: CGPoint(x: cx, y: rect.maxY), control: CGPoint(x: cx + inner, y: cy + inner))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: cy), control: CGPoint(x: cx - inner, y: cy + inner))
        path.addQuadCurve(to: CGPoint(x: cx, y: rect.minY), control: CGPoint(x: cx - inner, y: cy - inner))
        path.closeSubpath()
        return path
    }
}

/// Chrome-inspired top-right "Ask Gemini" capsule button.
struct AskGeminiToolbarButton: View {
    let isPresented: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var sparkleGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [
                Color(red: 0.92, green: 0.26, blue: 0.21), // Red
                Color(red: 0.26, green: 0.52, blue: 0.96), // Blue
                Color(red: 0.20, green: 0.66, blue: 0.33), // Green
                Color(red: 0.98, green: 0.74, blue: 0.02), // Yellow
                Color(red: 0.92, green: 0.26, blue: 0.21)  // Red
            ]),
            center: .center,
            angle: .degrees(-90)
        )
    }

    private var pillFill: Color {
        if isPresented {
            return colorScheme == .dark
                ? Color.white.opacity(0.18)
                : Color.accentColor.opacity(0.14)
        }
        if isHovering {
            return colorScheme == .dark
                ? Color.white.opacity(0.14)
                : Color.primary.opacity(0.09)
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.09)
            : Color.primary.opacity(0.055)
    }

    private var pillBorder: Color {
        if isPresented {
            return colorScheme == .dark
                ? Color.white.opacity(0.24)
                : Color.accentColor.opacity(0.35)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.09)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                GeminiSparkleShape()
                    .fill(sparkleGradient)
                    .frame(width: 13, height: 13)

                Text("Ask Gemini")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(pillFill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(pillBorder, lineWidth: 0.75)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(isPresented ? "Hide Ask Gemini (⌥⌘G)" : "Ask Gemini (⌥⌘G)")
        .accessibilityLabel("Ask Gemini")
        .accessibilityIdentifier("companion-ask-gemini-button")
        .accessibilityAddTraits(isPresented ? .isSelected : [])
    }
}

/// Installs the Chrome-style "Ask Gemini" pill button in the trailing edge of
/// the native macOS window titlebar (the top row, aligned with traffic lights).
struct AskGeminiTitlebarInstaller: NSViewRepresentable {
    let isPresented: Bool
    let onToggle: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: isPresented, onToggle: onToggle)
    }

    func makeNSView(context: Context) -> WindowObservationView {
        let view = WindowObservationView()
        view.isHidden = true
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowObservationView, context: Context) {
        context.coordinator.update(isPresented: isPresented, onToggle: onToggle)
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: WindowObservationView, coordinator: Coordinator) {
        nsView.onWindowChange = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var accessory: AskGeminiTitlebarAccessoryViewController?
        private var isPresented: Bool
        private var onToggle: @MainActor () -> Void

        init(isPresented: Bool, onToggle: @escaping @MainActor () -> Void) {
            self.isPresented = isPresented
            self.onToggle = onToggle
        }

        func update(isPresented: Bool, onToggle: @escaping @MainActor () -> Void) {
            self.isPresented = isPresented
            self.onToggle = onToggle
            accessory?.update(isPresented: isPresented, onToggle: onToggle)
        }

        func attach(to newWindow: NSWindow?) {
            guard let newWindow else {
                detach()
                return
            }
            if let window, window !== newWindow {
                removeAccessory(from: window)
            }
            window = newWindow

            let accessory = accessory ?? AskGeminiTitlebarAccessoryViewController(
                isPresented: isPresented,
                onToggle: onToggle
            )
            self.accessory = accessory
            accessory.update(isPresented: isPresented, onToggle: onToggle)

            guard !newWindow.titlebarAccessoryViewControllers.contains(where: { $0 === accessory }) else {
                return
            }
            newWindow.addTitlebarAccessoryViewController(accessory)
        }

        func detach() {
            if let window {
                removeAccessory(from: window)
            }
            window = nil
        }

        private func removeAccessory(from window: NSWindow) {
            guard let accessory,
                  let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory })
            else { return }
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }
}

@MainActor
private final class AskGeminiTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {
    private var hostingView: NSHostingView<AskGeminiToolbarButton>?
    private var isPresented: Bool
    private var onToggle: @MainActor () -> Void

    init(isPresented: Bool, onToggle: @escaping @MainActor () -> Void) {
        self.isPresented = isPresented
        self.onToggle = onToggle
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let hosting = NSHostingView(
            rootView: AskGeminiToolbarButton(isPresented: isPresented, action: onToggle)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.hostingView = hosting

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 118, height: 28))
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            hosting.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        view = container
    }

    func update(isPresented: Bool, onToggle: @escaping @MainActor () -> Void) {
        self.isPresented = isPresented
        self.onToggle = onToggle
        hostingView?.rootView = AskGeminiToolbarButton(isPresented: isPresented, action: onToggle)
    }
}

/// Hosts the session's persistent `WKWebView` without recreating it across SwiftUI updates.
private struct CompanionWebViewRepresentable: NSViewRepresentable {
    let session: CompanionBrowserSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        attachWebView(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        attachWebView(to: nsView)
    }

    private func attachWebView(to container: NSView) {
        let webView = session.ensureWebView()
        guard webView.superview !== container else { return }

        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

/// Resizable right-side companion browser drawer for reading alongside Gemini.
struct CompanionBrowserPanelView: View {
    @ObservedObject var session: CompanionBrowserSession
    let containerWidth: CGFloat

    @State private var isDraggingDivider = false
    @State private var dragStartWidth: CGFloat? = nil
    @State private var isHoveringDivider = false
    @State private var isEditingAddress = false
    @FocusState private var addressFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            resizeHandle
            VStack(spacing: 0) {
                headerBar
                progressLine
                if let toast = session.selectionToastMessage {
                    toastBanner(toast)
                }
                ZStack {
                    CompanionWebViewRepresentable(session: session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Prevent the embedded web page from swallowing mouse events while resizing.
                    if isDraggingDivider {
                        Color.clear
                            .contentShape(Rectangle())
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: CompanionBrowserLayoutPolicy.clampedWidth(session.panelWidth, in: containerWidth))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("companion-browser-panel")
    }

    private var resizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(isDraggingDivider ? Color.accentColor.opacity(0.65) : Color(nsColor: .separatorColor))
                .frame(width: isDraggingDivider ? 2 : 1)
        }
        .frame(width: 6)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering, !isHoveringDivider {
                isHoveringDivider = true
                NSCursor.resizeLeftRight.push()
            } else if !hovering, isHoveringDivider {
                isHoveringDivider = false
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    isDraggingDivider = true
                    if dragStartWidth == nil {
                        dragStartWidth = CompanionBrowserLayoutPolicy.clampedWidth(
                            session.panelWidth,
                            in: containerWidth
                        )
                    }
                    let start = dragStartWidth ?? session.panelWidth
                    // Dragging left increases the right-side drawer width.
                    let proposed = start - value.translation.width
                    session.updatePanelWidth(proposed, containerWidth: containerWidth)
                }
                .onEnded { _ in
                    isDraggingDivider = false
                    dragStartWidth = nil
                }
        )
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(CompanionBrowserPreset.allCases) { preset in
                    Button {
                        session.selectPreset(preset)
                    } label: {
                        HStack {
                            Label(preset.title, systemImage: preset.systemImage)
                            if session.activePreset == preset {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button("Open in Default Browser") {
                    session.openInExternalBrowser()
                }
                Button("Close & Release Memory", role: .destructive) {
                    session.closeAndReleaseMemory()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: session.activePreset?.systemImage ?? "globe")
                        .font(.system(size: 11, weight: .medium))
                    Text(session.activePreset?.title ?? "Web")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Switch site or release memory")

            HStack(spacing: 2) {
                navIconButton("chevron.left", help: "Back", disabled: !session.canGoBack) {
                    session.goBack()
                }
                navIconButton("chevron.right", help: "Forward", disabled: !session.canGoForward) {
                    session.goForward()
                }
                navIconButton(
                    session.isLoading ? "xmark" : "arrow.clockwise",
                    help: session.isLoading ? "Stop Loading" : "Reload",
                    disabled: false
                ) {
                    session.reloadOrStop()
                }
            }

            addressBar

            navIconButton("arrow.up.right.square", help: "Open in Default Browser", disabled: false) {
                session.openInExternalBrowser()
            }

            navIconButton("xmark", help: "Hide Panel (⌥⌘G)", disabled: false) {
                session.hide()
            }
            .accessibilityIdentifier("companion-browser-close")
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(.bar)
    }

    private var addressBar: some View {
        Group {
            if isEditingAddress {
                TextField("Enter URL or search", text: $session.addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($addressFieldFocused)
                    .onSubmit {
                        _ = session.navigate(toInput: session.addressText)
                        isEditingAddress = false
                        addressFieldFocused = false
                    }
                    .onExitCommand {
                        session.addressText = session.currentURL.absoluteString
                        isEditingAddress = false
                        addressFieldFocused = false
                    }
            } else {
                Button {
                    session.addressText = session.currentURL.absoluteString
                    isEditingAddress = true
                    DispatchQueue.main.async {
                        addressFieldFocused = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(CompanionBrowserLayoutPolicy.displayHost(for: session.currentURL))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isEditingAddress ? 0.09 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isEditingAddress ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08),
                    lineWidth: 0.75
                )
        )
        .onChange(of: addressFieldFocused) { _, focused in
            if !focused, isEditingAddress {
                isEditingAddress = false
            }
        }
    }

    private var progressLine: some View {
        GeometryReader { geometry in
            if session.isLoading {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: max(12, geometry.size.width * CGFloat(session.estimatedProgress)))
                    .animation(.easeOut(duration: 0.15), value: session.estimatedProgress)
            } else {
                Divider()
            }
        }
        .frame(height: 1.5)
    }

    private func toastBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 11, weight: .medium))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.10))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func navIconButton(
        _ systemName: String,
        help: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(disabled ? .tertiary : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}
