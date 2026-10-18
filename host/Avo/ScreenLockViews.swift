import AvoKit
import AvoWindowHost
import SwiftUI

// Android started with a screen lock (VMStatus.screenLock): the banner above
// every pane and the unlock sheet. The form is the one App Shim windows show
// (AvoWindowHost's ScreenLockForm); one unlock anywhere clears them all.

/// Above every pane while Android's screen lock keeps it locked. Unlock…
/// opens the sheet, which also opens by itself when Android starts locked.
struct ScreenLockBanner: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let lock = model.screenLock, model.daemonState == .connected {
            Banner(symbol: "lock.fill", tint: .orange,
                   text: "Android is locked by its screen lock. Your apps open after you unlock it.") {
                Button("Unlock…") { model.unlockSheetShown = true }
            }
            .sheet(isPresented: $model.unlockSheetShown) {
                UnlockAndroidSheet(lock: lock)
            }
        }
    }
}

/// The pattern, PIN or password, passed to Android; Cancel keeps the banner.
struct UnlockAndroidSheet: View {
    let lock: AndroidScreenLock
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            HStack(spacing: 6) {
                Text("Unlock Android")
                    .font(.title2.weight(.semibold))
                HelpButton("Unlock Android", "To change or turn off the screen lock, open Settings from your Android apps after unlocking.")
                    .font(.title3)
            }
            Text("Android started with a screen lock, so your apps stay closed until you unlock it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScreenLockForm(lock: lock, cancel: { model.unlockSheetShown = false }) { credential in
                try await model.unlockAndroid(credential: credential)
                model.unlockSheetShown = false
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 400)
    }
}
