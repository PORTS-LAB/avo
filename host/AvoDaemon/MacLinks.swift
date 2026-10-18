import AppKit
import AvoDaemonCore
import os

/// Opens the links Android apps open (VMMEngine.links, from Avo Links in
/// Android) with the Mac's default app for each, as WSA did on Windows: web
/// pages in the browser, e-mail in the mail app, phone numbers in FaceTime
/// (which asks before it calls), places in Maps (they come as Apple Maps links).
enum MacLinks {
    @MainActor
    static func open(_ url: URL, logger: Logger) {
        // GuestLinkPolicy let only these through. Any other scheme would start
        // whichever Mac app claims it, with text an Android app chose.
        guard let scheme = url.scheme?.lowercased(), GuestLinkPolicy.openableSchemes.contains(scheme) else {
            logger.error("not opening a \(url.scheme ?? "", privacy: .public): link from Android")
            return
        }
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                logger.error("could not open a link from Android: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
