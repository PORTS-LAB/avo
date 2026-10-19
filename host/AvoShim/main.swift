import AppKit

// App Shim loader. Every Android app gets a copy of this tiny bundle in
// ~/Applications/Android Apps/ so it has its own Dock icon and process (spec
// §4). The real work happens in AvoWindowHost.framework inside Avo.app, so
// updating Avo updates every shim at once.

private let info = Bundle.main.infoDictionary ?? [:]

@MainActor private func hostApplication() -> URL? {
    if let path = info["AvoHostApplication"] as? String, FileManager.default.fileExists(atPath: path) {
        return URL(filePath: path)
    }
    // Avo.app was moved: ask LaunchServices.
    let identifier = info["AvoHostBundleIdentifier"] as? String ?? "com.avodroid.emulator"
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
}

@MainActor private func fail(_ message: String) -> Never {
    let alert = NSAlert()
    alert.messageText = String(localized: "This Android app cannot open")
    alert.informativeText = message
    alert.runModal()
    exit(1)
}

guard let avo = hostApplication() else {
    fail(String(localized: "Avo is not installed. Install Avo again, then reopen this app."))
}
let framework = avo.appending(path: "Contents/Frameworks/AvoWindowHost.framework/AvoWindowHost")
guard let handle = dlopen(framework.path, RTLD_NOW | RTLD_LOCAL) else {
    fail(String(localized: "Avo’s window host could not be loaded: \(String(cString: dlerror()))"))
}
guard let symbol = dlsym(handle, "AvoShimMain") else {
    fail(String(localized: "This version of Avo is too old for this shortcut. Update Avo."))
}
typealias ShimMain = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
let main = unsafeBitCast(symbol, to: ShimMain.self)
exit(main(CommandLine.argc, CommandLine.unsafeArgv))
