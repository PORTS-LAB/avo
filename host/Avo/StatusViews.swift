import AvoKit
import SwiftUI

extension VMState {
    var label: LocalizedStringKey {
        switch self {
        case .notInstalled: "Android not installed"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .suspending: "Pausing"
        case .suspended: "Paused"
        case .stopping: "Stopping"
        case .failed: "Stopped with an error"
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .starting, .stopping, .suspending: .orange
        case .failed: .red
        default: .secondary
        }
    }

    var isBusy: Bool { self == .starting || self == .stopping || self == .suspending }
}

/// Sidebar footer: VM state, Android version and open windows.
struct VMStatusFooter: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        if model.daemonState == .connected {
            vmStatus
        } else {
            // Without the daemon the last known state may be long gone.
            HStack(spacing: 8) {
                Circle().fill(.secondary).frame(width: 8, height: 8)
                Text(model.daemonState == .connecting ? "Connecting…" : "Not connected").font(.callout.weight(.medium))
                Spacer(minLength: 0)
            }
        }
    }

    private var vmStatus: some View {
        let status = model.status
        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(status.state.color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.state.label).font(.callout.weight(.medium))
                if let detail = status.detail, status.state != .running {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                } else if let version = status.androidVersion {
                    Text(version).font(.caption).foregroundStyle(.secondary)
                }
                if status.openDisplays > 0 {
                    Text("\(status.openDisplays) open windows").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct VMControlButton: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        let state = model.status.state
        if state == .running {
            // A Google apps install restarts Android itself meanwhile.
            Button { model.stopVM() } label: { Label("Stop Android", systemImage: "stop.fill") }
                .disabled(model.googleAppsChangingAndroid)
                .help(model.googleAppsChangingAndroid
                      ? LocalizedStringKey("Available again when Avo finishes changing Google apps.")
                      : "Stop the Android VM. Open apps close.")
        } else if state == .suspended {
            // Starting a paused Android resumes it.
            Button { model.startVM() } label: { Label("Resume Android", systemImage: "play.fill") }
                .disabled(model.daemonState != .connected)
                .help("Android is paused to save energy. Opening an app resumes it too.")
        } else {
            Button { model.startVM() } label: { Label("Start Android", systemImage: "play.fill") }
                .disabled(state.isBusy || model.daemonState != .connected || model.googleAppsChangingAndroid)
                .help(model.googleAppsChangingAndroid
                      ? LocalizedStringKey("Available again when Avo finishes changing Google apps.")
                      : "Start the Android VM in the background.")
        }
    }
}

/// Formats byte counts the way Finder does.
func formatBytes(_ bytes: Int64?) -> String {
    guard let bytes, bytes > 0 else { return "—" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
