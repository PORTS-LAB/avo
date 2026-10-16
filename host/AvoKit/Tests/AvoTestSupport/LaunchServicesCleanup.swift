import Foundation

/// Replacing app bundles and creating Finder aliases to them registers them
/// with LaunchServices. Tests call this before deleting their temporary
/// directories so no stale app records are left on the developer's Mac.
public enum LaunchServicesCleanup {
    private static let lsregister = URL(filePath:
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")

    /// Unregisters every LaunchServices record whose path is under `root`,
    /// including bundles the test already deleted.
    public static func unregisterApps(under root: URL) {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        for path in registeredPaths() where path.hasPrefix(prefix) {
            run(["-u", path])
        }
    }

    private static func registeredPaths() -> [String] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = lsregister
        process.arguments = ["-dump"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard line.hasPrefix("path:") else { return nil }
            var path = line.dropFirst("path:".count).trimmingCharacters(in: .whitespaces)
            if let suffix = path.range(of: #" \(0x[0-9a-f]+\)$"#, options: .regularExpression) { path.removeSubrange(suffix) }
            return path
        }
    }

    private static func run(_ arguments: [String]) {
        let process = Process()
        process.executableURL = lsregister
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
