import AvoKit
import SwiftUI
import UniformTypeIdentifiers

enum Pane: String, CaseIterable, Identifiable {
    case apps, performance, storage, graphics, display, system

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .apps: "Apps"
        case .performance: "Performance"
        case .storage: "Storage"
        case .graphics: "Graphics"
        case .display: "Display"
        case .system: "System"
        }
    }

    var symbol: String {
        switch self {
        case .apps: "square.grid.2x2"
        case .performance: "speedometer"
        case .storage: "internaldrive"
        case .graphics: "cpu"
        case .display: "macwindow"
        case .system: "gearshape.2"
        }
    }
}

struct ContentView: View {
    @Environment(ControlPanelModel.self) private var model
    @State private var pane: Pane = .apps
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $pane) {
                Section {
                    Label(Pane.apps.title, systemImage: Pane.apps.symbol).tag(Pane.apps)
                }
                Section("Settings") {
                    ForEach(Pane.allCases.dropFirst()) { pane in
                        Label(pane.title, systemImage: pane.symbol).tag(pane)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { VMStatusFooter().padding(12) }
        } detail: {
            VStack(spacing: 0) {
                DaemonBanner()
                if model.pendingRestart && pane != .apps {
                    RestartBanner()
                }
                detail
            }
            .navigationTitle(pane.title)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                VMControlButton()
                Button {
                    (NSApp.delegate as? AppDelegate)?.chooseAndInstall()
                } label: {
                    Label("Install App", systemImage: "plus")
                }
                .help("Install an .apk, .xapk, .apkm or .apks file")
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if dropTargeted { DropOverlay() }
        }
        .sheet(item: $model.pendingInstall) { _ in
            InstallSheet()
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .apps: AppsView()
        case .performance: PerformancePane()
        case .storage: StoragePane()
        case .graphics: GraphicsPane()
        case .display: DisplayPane()
        case .system: SystemPane()
        }
    }

    /// Spec §3: dragging a package onto the Control Panel installs it.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.prepareInstall(url) }
        }
        return true
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                Label("Drop to install", systemImage: "arrow.down.app")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(12)
            .allowsHitTesting(false)
    }
}

/// Shown while the daemon is missing or waiting for Login Items approval.
private struct DaemonBanner: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        switch model.daemonState {
        case .connected:
            EmptyView()
        case .connecting:
            Banner(symbol: "hourglass", tint: .secondary, text: "Connecting to Avo's background service…")
        case .needsApproval:
            Banner(symbol: "exclamationmark.shield", tint: .orange,
                   text: "Allow Avo in System Settings › General › Login Items so Android can run in the background.") {
                Button("Open Login Items") { model.openLoginItemsSettings() }
            }
        case .unavailable(let reason):
            Banner(symbol: "bolt.horizontal.circle", tint: .red, text: "Avo's background service is not running. \(reason)") {
                Button("Retry") { model.connect() }
            }
        }
    }
}

private struct RestartBanner: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        Banner(symbol: "arrow.clockwise.circle", tint: .accentColor,
               text: "Some changes apply after Android restarts. Your apps and data are kept.") {
            Button("Restart Android") { model.restartVM() }
        }
    }
}

struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: LocalizedStringKey
    @ViewBuilder var actions: Actions

    init(symbol: String, tint: Color, text: LocalizedStringKey, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.tint = tint
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}
