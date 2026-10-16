import AvoKit
import CoreServices
import Foundation
import Security

/// Creates and maintains the per-app `.app` bundles in
/// `~/Applications/Android Apps/` that give every Android app its own Dock
/// icon, Launchpad entry and Spotlight result (spec §4).
///
/// Each shim is a copy of the template bundle shipped inside Avo.app with its
/// own Info.plist and icon. Editing a signed bundle breaks its signature, so
/// shims are re-signed ad hoc; the daemon pins each shim's code directory hash
/// and only accepts XPC connections from shims it created.
public struct ShimBuilder: Sendable {
    public struct Result: Sendable, Equatable {
        public let bundleURL: URL
        public let cdhash: String
    }

    public enum Failure: Error, Equatable, Sendable {
        case templateMissing(String)
        case signingFailed(String)
        case io(String)
    }

    /// The App Shim template (Avo.app/Contents/Library/Shim/AvoShim.app).
    public let template: URL
    /// Avo.app, recorded in each shim so it can find AvoWindowHost.framework.
    public let hostApplication: URL
    public let directory: URL
    /// Register new shims with LaunchServices so Launchpad and Spotlight pick
    /// them up immediately (tests turn this off).
    public var registersWithLaunchServices = true

    public init(template: URL, hostApplication: URL, directory: URL) {
        self.template = template
        self.hostApplication = hostApplication
        self.directory = directory
    }

    /// Creates or updates the shim for `app`, renaming it when the label
    /// changed. `icns` is the rendered icon.
    public func install(_ app: AppRecord, icns: Data, existing: URL? = nil) throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: template.appending(path: "Contents/Info.plist").path) else {
            throw Failure.templateMissing(template.path)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = bundleURL(for: app, existing: existing)

        // Build in a staging directory next to the destination, then swap it in,
        // so a running shim never sees a half-written bundle.
        let staging = directory.appending(path: ".\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.copyItem(at: template, to: staging)
            let resources = staging.appending(path: "Contents/Resources")
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            try icns.write(to: resources.appending(path: "AppIcon.icns"))
            try writeInfoPlist(for: app, in: staging)
        } catch {
            throw Failure.io(error.localizedDescription)
        }
        let cdhash = try Self.signAdHoc(staging, identifier: AvoIdentifiers.shimBundleIdentifier(for: app.package))

        do {
            if let existing, existing != destination, fm.fileExists(atPath: existing.path) {
                try fm.removeItem(at: existing)
            }
            if fm.fileExists(atPath: destination.path) {
                // Atomic swap, so a running shim never sees a half-written bundle.
                // (FileManager.replaceItemAt would also register the bundle with
                // LaunchServices behind our back.)
                guard renamex_np(staging.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw Failure.io(String(cString: strerror(errno)))
                }
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            throw Failure.io(error.localizedDescription)
        }
        if registersWithLaunchServices { LSRegisterURL(destination as CFURL, true) }
        return Result(bundleURL: destination, cdhash: cdhash)
    }

    public func remove(_ bundle: URL) throws {
        guard bundle.path.hasPrefix(directory.path + "/"), bundle.pathExtension == "app" else { return }
        if FileManager.default.fileExists(atPath: bundle.path) {
            try FileManager.default.removeItem(at: bundle)
        }
    }

    /// `<Label>.app`, or `<Label> (<package>).app` when another app already uses the name.
    public func bundleURL(for app: AppRecord, existing: URL? = nil) -> URL {
        let name = Self.fileName(for: app.displayName)
        let preferred = directory.appending(path: "\(name).app", directoryHint: .isDirectory)
        if preferred == existing || !FileManager.default.fileExists(atPath: preferred.path) || owner(of: preferred) == app.package {
            return preferred
        }
        return directory.appending(path: "\(name) (\(app.package)).app", directoryHint: .isDirectory)
    }

    /// The Android package a bundle in the shims directory belongs to.
    public func owner(of bundle: URL) -> String? {
        let plist = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info[AvoIdentifiers.shimPackageInfoKey] as? String
    }

    /// Every shim in the directory, by package.
    public func existingShims() -> [String: URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [String: URL] = [:]
        for found in contents where found.pathExtension == "app" && !found.lastPathComponent.hasPrefix(".") {
            // Rebuild from `directory` so paths match the registry (no /private symlink resolution).
            let url = directory.appending(path: found.lastPathComponent, directoryHint: .isDirectory)
            if let package = owner(of: url) { result[package] = url }
        }
        return result
    }

    /// File name (without .app) used for a shim with this label.
    public static func fileName(for label: String) -> String {
        let cleaned = label.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return trimmed.isEmpty ? "Android App" : String(trimmed.prefix(200))
    }

    private func writeInfoPlist(for app: AppRecord, in bundle: URL) throws {
        let url = bundle.appending(path: "Contents/Info.plist")
        let data = try Data(contentsOf: url)
        guard var info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure.io("template Info.plist is not a dictionary")
        }
        info["CFBundleIdentifier"] = AvoIdentifiers.shimBundleIdentifier(for: app.package)
        info["CFBundleName"] = app.displayName
        info["CFBundleDisplayName"] = app.displayName
        info["CFBundleIconFile"] = "AppIcon"
        info["CFBundleIconName"] = nil
        info["CFBundleShortVersionString"] = app.versionName.isEmpty ? "1.0" : app.versionName
        info["CFBundleVersion"] = String(app.versionCode)
        info[AvoIdentifiers.shimPackageInfoKey] = app.package
        info[AvoIdentifiers.shimHostAppInfoKey] = hostApplication.path
        let output = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try output.write(to: url)
    }

    // MARK: Code signing

    /// Signs `bundle` ad hoc and returns its code directory hash (hex).
    static func signAdHoc(_ bundle: URL, identifier: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--identifier", identifier, "--timestamp=none", bundle.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure.signingFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure.signingFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let cdhash = cdhash(of: bundle) else { throw Failure.signingFailed("no code directory hash") }
        return cdhash
    }

    /// The code directory hash of a signed bundle, as lowercase hex.
    public static func cdhash(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let unique = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
