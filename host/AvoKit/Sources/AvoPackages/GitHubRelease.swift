import CryptoKit
import Foundation

/// A GitHub release as the REST API describes it (only what Avo reads), for
/// Google apps from GitHub in Settings › Google Apps (GoogleAppsReleases.swift).
public struct GitHubRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let size: UInt64
        public let browserDownloadURL: URL
        /// `sha256:<hex>`, which GitHub computes for every uploaded asset.
        public let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }

        public init(name: String, size: UInt64, browserDownloadURL: URL, digest: String? = nil) {
            self.name = name
            self.size = size
            self.browserDownloadURL = browserDownloadURL
            self.digest = digest
        }

        /// The SHA-256 GitHub computed, as lowercase hex.
        public var sha256: String? { Checksum.sha256(fromDigest: digest) }
    }

    public let tagName: String
    public let assets: [Asset]
    /// When it was published (nil for a draft).
    public let publishedAt: Date?
    public let draft: Bool
    public let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
        case publishedAt = "published_at"
        case draft, prerelease
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        assets = try container.decode([Asset].self, forKey: .assets)
        // `2026-10-06T11:13:02Z`; a release that was never published has null.
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt).flatMap { try? Date($0, strategy: .iso8601) }
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
    }

    public static func parse(_ data: Data) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// A repository's release list (`/repos/<owner>/<repo>/releases`), newest first.
    public static func parseList(_ data: Data) throws -> [GitHubRelease] {
        try JSONDecoder().decode([GitHubRelease].self, from: data)
    }

    /// Where the API describes the release a pasted link points at, and the
    /// asset it names, if any:
    /// - `github.com/<owner>/<repo>[/releases[/latest]]` → the latest release;
    /// - `github.com/<owner>/<repo>/releases/tag/<tag>` → that release;
    /// - `github.com/<owner>/<repo>/releases/download/<tag>/<file>` → that release, that file;
    /// - `api.github.com/repos/<owner>/<repo>/releases/…` as it is.
    public static func apiURL(for link: String) throws -> (url: URL, asset: String?) {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: text.contains("://") ? text : "https://" + text),
              components.scheme?.lowercased() == "https", let host = components.host?.lowercased() else {
            throw GoogleAppsError.invalidReleaseURL(link)
        }
        let parts = components.path.split(separator: "/").map(String.init)
        components.query = nil
        components.fragment = nil
        if host == "api.github.com" {
            guard parts.count >= 4, parts[0] == "repos", parts[3] == "releases", let url = components.url else {
                throw GoogleAppsError.invalidReleaseURL(link)
            }
            return (url, nil)
        }
        guard host == "github.com" || host == "www.github.com", parts.count >= 2 else {
            throw GoogleAppsError.invalidReleaseURL(link)
        }
        let owner = parts[0]
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let rest = Array(parts.dropFirst(2))
        let release: String
        var asset: String?
        switch rest.count {
        case 0:
            release = "latest"
        case 1 where rest[0] == "releases":
            release = "latest"
        case 2 where rest == ["releases", "latest"]:
            release = "latest"
        case 3 where rest[0] == "releases" && rest[1] == "tag":
            release = "tags/" + encode(rest[2])
        case 4 where rest[0] == "releases" && rest[1] == "download":
            release = "tags/" + encode(rest[2])
            asset = rest[3]
        default:
            throw GoogleAppsError.invalidReleaseURL(link)
        }
        guard !owner.isEmpty, !repo.isEmpty,
              let url = URL(string: "https://api.github.com/repos/\(encode(owner))/\(encode(repo))/releases/\(release)") else {
            throw GoogleAppsError.invalidReleaseURL(link)
        }
        return (url, asset)
    }

    private static func encode(_ part: String) -> String {
        part.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? part
    }

    /// The flashable .zip: the one named `preferred` when given, otherwise
    /// the only .zip (an arm64 one when there are several).
    public func packageAsset(preferring preferred: String? = nil) -> Asset? {
        let zips = assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        if let preferred { return zips.first { $0.name == preferred } }
        if zips.count == 1 { return zips[0] }
        return zips.first { $0.name.lowercased().contains("arm64") }
    }

    /// The `<zip>.sha256sum` file published next to the package.
    public func checksumAsset(for asset: Asset) -> Asset? {
        assets.first { $0.name == asset.name + ".sha256sum" || $0.name == asset.name + ".sha256" }
    }
}

public enum Checksum {
    /// `sha256:6b38…` → `6b38…`.
    public static func sha256(fromDigest digest: String?) -> String? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        return hex(String(digest.dropFirst("sha256:".count)))
    }

    /// `sha256sum` output: `<hex>  <name>` lines (or a bare hash).
    public static func sha256(fromSumFile text: String, name: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        for words in lines where words.count >= 2 {
            // `*name` marks binary mode.
            let file = words[1].hasPrefix("*") ? String(words[1].dropFirst()) : words[1]
            if file == name || (file as NSString).lastPathComponent == name { return hex(words[0]) }
        }
        if lines.count == 1, lines[0].count == 1 { return hex(lines[0][0]) }
        return nil
    }

    private static func hex(_ text: String) -> String? {
        let value = text.lowercased()
        return value.count == 64 && value.allSatisfy(\.isHexDigit) ? value : nil
    }

    /// SHA-256 of a file as lowercase hex, read in chunks.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
