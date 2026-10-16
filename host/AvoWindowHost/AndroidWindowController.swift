import AppKit
import AvoKit
import AvoProtocol

/// One macOS window showing one Android VirtualDisplay (spec: "satu NSWindow
/// per VirtualDisplay").
@MainActor
final class AndroidWindowController: NSWindowController, NSWindowDelegate {
    private weak var app: ShimAppDelegate?
    private let frames: FrameRouter
    private let displayView: DisplayView
    private let placeholder = PlaceholderView()
    private var client: DaemonClient?
    private(set) var displayID: UInt32?
    private var keymap: KeymapController?
    private var resizeTask: Task<Void, Never>?
    private var closingFromGuest = false
    private var lastSentSize: (UInt32, UInt32, UInt32)?

    init(app: ShimAppDelegate, frames: FrameRouter) {
        self.app = app
        self.frames = frames
        guard let renderer = MetalRenderer() else { fatalError("Metal is unavailable") }
        displayView = DisplayView(renderer: renderer)

        let config = app.config
        var size = config.defaultWindowSize
        if config.defaultOrientation == .landscape { size = size.rotated }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = app.label
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: 240, height: 240)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let container = NSView()
        displayView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(displayView)
        container.addSubview(placeholder)
        NSLayoutConstraint.activate([
            displayView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            displayView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            displayView.topAnchor.constraint(equalTo: container.topAnchor),
            displayView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: container.topAnchor),
            placeholder.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        placeholder.show(icon: NSApp.applicationIconImage, message: "Starting \(app.label)…", busy: true)
        displayView.onDropFiles = { [weak self] urls in self?.share(urls) }

        // Remember each app's window frame separately; offset extra windows.
        window.setFrameAutosaveName("AvoWindow-\(app.package)")
        if window.frame.origin == .zero { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Display lifecycle

    func attach(client: DaemonClient, notificationKey: String?) {
        guard let app else { return }
        self.client = client
        let (width, height, dpi) = pixelSize()
        Task { [weak self] in
            guard let self else { return }
            do {
                let id = try await client.openDisplay(OpenDisplayRequest(package: app.package, width: width, height: height,
                                                                         dpi: dpi, notificationKey: notificationKey))
                displayID = id
                lastSentSize = (width, height, dpi)
                displayView.displayID = id
                displayView.setDisplaySize(CGSize(width: Int(width), height: Int(height)))
                frames.register(displayView, for: id)
                let keymap = KeymapController(package: app.package, displayID: id, view: displayView,
                                              hostApplication: Self.hostApplication) { [weak self] record in
                    self?.sendInput(record)
                }
                self.keymap = keymap
                displayView.keymap = keymap
                displayView.send = { [weak self] record in self?.sendInput(record) }
            } catch {
                showProblem((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func sendInput(_ record: InputRecord) {
        guard let client, let bytes = try? InputWire.encode(record) else { return }
        client.sendInput(Data(bytes))
    }

    func displayReady() {
        displayView.renderer.whenNextFrameShown { [weak self] in self?.placeholder.hide() }
        // A display without frames yet (no engine attached) keeps a quiet placeholder.
        placeholder.show(icon: NSApp.applicationIconImage, message: nil, busy: true)
    }

    func showProblem(_ message: String) {
        placeholder.show(icon: NSApp.applicationIconImage, message: message, busy: false)
    }

    func closeFromGuest() {
        closingFromGuest = true
        close()
    }

    func detach() {
        guard let displayID, !closingFromGuest else { return }
        client?.closeDisplay(displayID)
        frames.unregister(displayID)
        self.displayID = nil
    }

    func share(_ urls: [URL]) {
        guard let client, let displayID else { return }
        Task {
            do {
                try await client.shareFiles(urls, with: displayID)
            } catch {
                showProblem(error.localizedDescription)
            }
        }
    }

    /// Display size in pixels and density for the window's current content size.
    private func pixelSize() -> (UInt32, UInt32, UInt32) {
        guard let window, let app else { return (1080, 2340, 320) }
        let config = app.config
        let scale = config.retinaScaling ? window.backingScaleFactor : 1
        let content = window.contentLayoutRect.size
        let width = UInt32(max(content.width * scale, 240).rounded())
        let height = UInt32(max(content.height * scale, 240).rounded())
        // 160 dpi per point keeps 1 dp = 1 pt, so apps look the same size as Mac UI.
        let dpi = UInt32(config.defaultDPI ?? Int(160 * scale))
        return (width & ~1, height & ~1, dpi)
    }

    static var hostApplication: URL? {
        (Bundle.main.object(forInfoDictionaryKey: AvoIdentifiers.shimHostAppInfoKey) as? String).map { URL(filePath: $0) }
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        scheduleResize(delay: .milliseconds(250))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        scheduleResize(delay: .zero)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        scheduleResize(delay: .zero)
    }

    private func scheduleResize(delay: Duration) {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, let displayID = self.displayID, let client = self.client else { return }
            let size = self.pixelSize()
            guard self.lastSentSize.map({ $0 != size }) ?? true else { return }
            self.lastSentSize = size
            self.displayView.setDisplaySize(CGSize(width: Int(size.0), height: Int(size.1)))
            client.resizeDisplay(displayID, width: size.0, height: size.1, dpi: size.2)
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if let displayID { client?.setDisplayVisible(displayID, visible: false) }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if let displayID { client?.setDisplayVisible(displayID, visible: true) }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window, let displayID, !window.isMiniaturized else { return }
        client?.setDisplayVisible(displayID, visible: window.occlusionState.contains(.visible))
    }

    func windowDidResignKey(_ notification: Notification) {
        // Never keep keys or the pointer captured after focus leaves the game.
        keymap?.focusLost()
    }

    func windowWillClose(_ notification: Notification) {
        keymap?.stop()
        detach()
        app?.windowClosed(self)
    }

    // MARK: Orientation

    func applyOrientation(_ orientation: DisplayOrientation) {
        guard let window else { return }
        let size = window.contentLayoutRect.size
        let wantsLandscape: Bool
        switch orientation {
        case .landscape, .reverseLandscape: wantsLandscape = true
        case .portrait, .reversePortrait: wantsLandscape = false
        case .unspecified: return
        }
        if (size.width > size.height) != wantsLandscape { rotateWindow() }
    }

    @objc func rotateWindow() {
        guard let window else { return }
        let content = window.contentLayoutRect.size
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: content.height, height: content.width)))
        var origin = window.frame.origin
        origin.y += window.frame.height - frame.height // keep the title bar in place
        window.setFrame(NSRect(origin: origin, size: frame.size), display: true, animate: true)
    }

    @objc func sendBack() {
        displayView.sendBack()
    }

    @objc func toggleKeymapEditor() {
        keymap?.toggleEditor(over: window)
    }
}

/// Icon, spinner and message shown until the first frame (or on errors).
final class PlaceholderView: NSView {
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        spinner.style = .spinning
        spinner.controlSize = .small
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let stack = NSStackView(views: [icon, spinner, label])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(icon image: NSImage?, message: String?, busy: Bool) {
        isHidden = false
        icon.image = image
        label.stringValue = message ?? ""
        label.isHidden = message == nil
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !busy
    }

    func hide() {
        spinner.stopAnimation(nil)
        isHidden = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : super.hitTest(point)
    }
}
