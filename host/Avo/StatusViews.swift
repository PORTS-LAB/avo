import AvoKit
import SwiftUI

extension VMState {
    var label: LocalizedStringKey {
        switch self {
        case .notInstalled: "Android not installed"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .suspending: "Saving state"
        case .suspended: "Suspended"
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
        let status = model.status
        HStack(alignment: .top, spacing: 8) {
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
            Button { model.stopVM() } label: { Label("Stop Android", systemImage: "stop.fill") }
                .help("Stop the Android VM. Open apps close.")
        } else {
            Button { model.startVM() } label: { Label("Start Android", systemImage: "play.fill") }
                .disabled(state.isBusy || model.daemonState != .connected)
                .help("Start the Android VM in the background.")
        }
    }
}

/// Formats byte counts the way Finder does.
func formatBytes(_ bytes: Int64?) -> String {
    guard let bytes, bytes > 0 else { return "—" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
