import AvoKit
import AvoProtocol
import AvoShimKit
import CoreGraphics
import Foundation
import os

/// Keeps App Shims, Desktop aliases and Dock tiles in line with the registry
/// and the shortcut options (spec §4).
public struct ShortcutManager: Sendable {
    public let builder: ShimBuilder?
    public let paths: AvoPaths
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Shortcuts")

    /// `builder` is nil when the shim template is missing (unit tests, broken install).
    public init(builder: ShimBuilder?, paths: AvoPaths) {
        self.builder = builder
        self.paths = paths
    }

    /// Creates or refreshes shortcuts for a launchable app and returns the new state.
    public func apply(_ app: AppRecord, info: Avo_V1_AppInfo?, config: VMConfig) -> AppRecord.Shortcuts {
        var shortcuts = app.shortcuts
        // The Bridge Agent decides which system apps are user-facing (launchable).
        guard app.launchable, let builder else { return shortcuts }

        let existing = shortcuts.shimPath.map { URL(filePath: $0) }
        let source = info.map(Self.iconSource) ?? iconSourceFromCache(app.package)
        guard let icns = MacIconRenderer.icns(source) else { return shortcuts }
        do {
            let result = try builder.install(app, icns: icns, existing: existing)
            if let old = shortcuts.desktopAliasPath, existing != result.bundleURL {
                Shortcuts.removeAlias(URL(filePath: old))
                shortcuts.desktopAliasPath = nil
            }
            shortcuts.shimPath = result.bundleURL.path
            shortcuts.shimCDHash = result.cdhash
        } catch {
            logger.error("shim for \(app.package, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return shortcuts
        }

        let shim = URL(filePath: shortcuts.shimPath!)
        if config.createDesktopAlias, shortcuts.desktopAliasPath == nil {
            shortcuts.desktopAliasPath = (try? Shortcuts.createAlias(to: shim, in: paths.desktop))?.path
        } else if !config.createDesktopAlias, let alias = shortcuts.desktopAliasPath {
            Shortcuts.removeAlias(URL(filePath: alias))
            shortcuts.desktopAliasPath = nil
        }
        if config.addToDock && !shortcuts.inDock {
            shortcuts.inDock = Shortcuts.addToDock(shim) || Shortcuts.isInDock(shim)
        } else if !config.addToDock && shortcuts.inDock {
            _ = Shortcuts.removeFromDock(shim)
            shortcuts.inDock = false
        }
        return shortcuts
    }

    /// Uninstall removes the shim and its alias (spec §4).
    public func remove(_ shortcuts: AppRecord.Shortcuts) {
        if let alias = shortcuts.desktopAliasPath { Shortcuts.removeAlias(URL(filePath: alias)) }
        if let shim = shortcuts.shimPath {
            let url = URL(filePath: shim)
            if shortcuts.inDock { _ = Shortcuts.removeFromDock(url) }
            try? builder?.remove(url)
        }
    }

    // MARK: Icons

    static func iconSource(_ info: Avo_V1_AppInfo) -> MacIconRenderer.Source {
        if info.hasAdaptiveIcon {
            let icon = info.adaptiveIcon
            let background = MacIconRenderer.image(from: icon.backgroundPng).map(MacIconRenderer.Layer.image)
            let foreground = MacIconRenderer.image(from: icon.foregroundPng).map(MacIconRenderer.Layer.image)
            if background != nil || foreground != nil {
                return .adaptive(background: background, foreground: foreground)
            }
        }
        if let image = MacIconRenderer.image(from: info.iconPng) { return .legacy(image) }
        return placeholder
    }

    private func iconSourceFromCache(_ package: String) -> MacIconRenderer.Source {
        guard let data = try? Data(contentsOf: paths.icon(for: package)), let image = MacIconRenderer.image(from: data) else {
            return Self.placeholder
        }
        return .legacy(image)
    }

    /// Avo's flesh green with nothing on it, for apps without a readable icon.
    static let placeholder = MacIconRenderer.Source.adaptive(
        background: .color(CGColor(srgbRed: 0.847, green: 0.910, blue: 0.655, alpha: 1)), foreground: nil)
}
