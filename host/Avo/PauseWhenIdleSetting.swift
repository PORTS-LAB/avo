import AvoKit
import SwiftUI

/// Settings › Performance › Pause when idle (`VMConfig.autoPauseMinutes`,
/// the daemon's AutoPause.swift): Never, or after 5, 15 or 30 minutes with
/// no Avo window open and nothing under way. Applies at once.
struct PauseWhenIdleSection: View {
    @Environment(ControlPanelModel.self) private var model
    let config: VMConfig

    var body: some View {
        Section {
            LabeledContent {
                HazePicker("Pause when idle", selection: Binding(get: { config.autoPauseMinutes },
                                                                 set: { value in model.update { $0.autoPauseMinutes = value } })) {
                    Text("Never").tag(0)
                    ForEach(VMConfig.autoPauseChoices.filter { $0 > 0 }, id: \.self) { minutes in
                        Text("After \(minutes) minutes").tag(minutes)
                    }
                }
            } label: {
                HelpTitle("Pause when idle") {
                    Text("When no Avo window has been open for this long and nothing is under way (an install, a download, sound, adb), Android pauses to save energy. It keeps its place and uses no CPU.")
                    Text("Opening an app, avoctl or adb resumes it within a moment. While it is paused, Android does nothing in the background, so its notifications wait too.")
                }
            }
            IssueText(field: "autoPauseMinutes")
        }
    }
}
