import AvoKit
import AvoPackages
import Foundation
import os

extension CuttlefishImage {
    /// The image Android starts with now, for VMManager's `loadImage`: the
    /// one chosen in the Setup Assistant or Settings › System › Android
    /// version (`AndroidImageStore`), unless the `AvoCuttlefishImages`
    /// developer setting names another. Read at every start, so a newly
    /// installed or chosen image needs no daemon restart.
    ///
    /// An image Avo installed is checked against its manifest (sizes and
    /// SHA-256, `AndroidImageStore.verify`); one used where it is (a
    /// scripts/fetch-cuttlefish.sh download) has nothing to check against.
    /// When avo-vmm's writable copies of super and vbmeta come from another
    /// image, they go, and avo-vmm makes new ones from this image.
    public static func prepareStart(paths: AvoPaths, override: String?) throws -> AndroidImage {
        let store = AndroidImageStore(paths: paths)
        let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "avo-vmm")
        guard let image = store.imageForBoot(override: override) else { throw AvoError.imageMissing }
        logger.notice("Android image: \(image.path, privacy: .public) (\(image.name, privacy: .public), build \(image.build ?? "?", privacy: .public))")
        try store.verify(image)
        // Never an older Android on newer data (carried from a Mac with a newer
        // one, or another image chosen meanwhile): it could not use it.
        if let problem = store.newerDataProblem(starting: image, override: override) {
            logger.error("refused: \(problem.message, privacy: .public)")
            throw AvoError.storage(problem)
        }
        // An instance made before these records came from what an older Avo picked.
        switch try store.prepareStart(with: image, unrecorded: find(paths: paths, override: override)) {
        case .none:
            break
        case .replaced:
            logger.notice("the Android image changed: avo-vmm makes new copies of super and vbmeta")
        case .replacedKeepingVerifiedBootOff:
            logger.notice("the Android image changed (same Android version): new copies, verified boot stays off")
        }
        return AndroidImage(schema: 1, version: "cuttlefish-\(image.build ?? "local")", sdk: image.release?.sdk ?? 0,
                            kernel: "boot.img", initrd: nil, partitions: [], overlayStock: "", overlayRooted: "", files: [],
                            directory: image.directory)
    }
}
