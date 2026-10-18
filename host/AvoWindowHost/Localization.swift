import Foundation

extension Bundle {
    /// This framework, for `String(localized:bundle:)`. The App Shim is the
    /// main bundle; it lists the languages Avo supports (CFBundleLocalizations)
    /// so the framework's text follows the user's language.
    static let windowHost = Bundle(for: ShimAppDelegate.self)
}
