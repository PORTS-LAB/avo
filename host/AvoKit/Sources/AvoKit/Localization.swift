import Foundation

extension Bundle {
    /// Localized text of every module in the AvoKit package
    /// (`Resources/Localizable.xcstrings`). Use it as
    /// `String(localized: "…", bundle: .avoKit)`.
    ///
    /// Xcode copies package resource bundles into each app that links the
    /// package (Avo.app, AvoDaemon.app), not into AvoHostKit.framework, so the
    /// generated `Bundle.module` traps in processes that only load the
    /// framework, such as App Shims. This also looks in the app that contains
    /// the framework, and falls back to the main bundle, which shows the
    /// English source text.
    public static let avoKit: Bundle = {
        let name = "AvoKit_AvoKit.bundle"
        let framework = Bundle(for: LocalizationAnchor.self)
        let directories: [URL?] = [
            // Avo.app, AvoDaemon.app, and avoctl (whose main bundle is Avo.app).
            Bundle.main.resourceURL,
            // A framework or test bundle that carries its own resources.
            framework.resourceURL,
            // App Shims: Avo.app/Contents/Frameworks/AvoHostKit.framework → Avo.app/Contents/Resources.
            framework.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources"),
            // Command-line tools built next to the bundle.
            Bundle.main.bundleURL,
            framework.bundleURL.deletingLastPathComponent(),
        ]
        for case let directory? in directories {
            if let bundle = Bundle(url: directory.appending(path: name)) { return bundle }
        }
        return .main
    }()
}

private final class LocalizationAnchor {}
