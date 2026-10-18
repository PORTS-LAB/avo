import AvoKit
import Foundation
import Testing
@testable import AvoKeymap

/// `KeymapProfile.usable(for:bundledDirectory:)`, the one definition of "this
/// app has a key mapping" (it also picks the Games graphics defaults).
@Suite struct KeymapProfileLookupTests {
    private let package = "com.example.game"
    private let root = FileManager.default.temporaryDirectory.appending(path: "avo-keymap-lookup-\(UUID())", directoryHint: .isDirectory)
    private var paths: AvoPaths { AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp")) }
    private var bundled: URL { root.appending(path: "bundled", directoryHint: .isDirectory) }

    /// Writes a profile that decodes; `valid: false` gives it no package, which `validate()` refuses.
    private func write(valid: Bool, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let profile = KeymapProfile(package: valid ? package : "", name: "Test", controls: [])
        try profile.encoded().write(to: url)
    }

    @Test func userProfileWins() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(valid: true, to: paths.keymap(for: package))
        try write(valid: true, to: bundled.appending(path: "\(package).json"))
        #expect(KeymapProfile.usable(for: package, bundledDirectory: bundled, paths: paths)?.url == paths.keymap(for: package))
    }

    @Test func invalidUserProfileFallsBackToTheBundledOne() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(valid: false, to: paths.keymap(for: package))
        try write(valid: true, to: bundled.appending(path: "\(package).json"))
        let found = KeymapProfile.usable(for: package, bundledDirectory: bundled, paths: paths)
        #expect(found?.url == bundled.appending(path: "\(package).json"))
        #expect(found?.profile.package == package)
    }

    @Test func noUsableProfile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(valid: false, to: paths.keymap(for: package))
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: bundled.appending(path: "\(package).json"))
        #expect(KeymapProfile.usable(for: package, bundledDirectory: bundled, paths: paths) == nil)
        #expect(KeymapProfile.usable(for: "com.other", bundledDirectory: nil, paths: paths) == nil)
    }
}
