import Foundation

/// A device identity template (spec §8, "Mock nama sistem").
///
/// Templates live as JSON files in `profiles/devices/` so the community can
/// add devices through pull requests. The Bridge Agent applies `properties`
/// at boot; changing the profile needs a VM restart.
///
/// A profile changes what apps read from `Build.*`. It does not and cannot
/// pass hardware attestation, and the UI says so.
public struct DeviceProfile: Codable, Identifiable, Equatable, Sendable {
    public struct Display: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var dpi: Int
    }

    /// Avo's honest default identity.
    public static let defaultID = "avo-virtual-device"
    /// The user-editable profile.
    public static let customID = "custom"

    /// Properties every template must define.
    public static let requiredProperties = [
        "ro.product.brand",
        "ro.product.manufacturer",
        "ro.product.model",
        "ro.product.device",
        "ro.build.fingerprint",
    ]

    /// Only identity properties may be overridden; anything else (security
    /// state, debuggability, verified boot) is rejected.
    public static let allowedPropertyPrefixes = [
        "ro.product.", "ro.build.fingerprint", "ro.build.description", "ro.build.product",
        "ro.build.display.id", "ro.build.version.incremental", "ro.build.id", "ro.build.tags",
        "ro.build.type", "ro.soc.manufacturer", "ro.soc.model", "ro.hardware",
    ]

    public static let forbiddenProperties: Set<String> = [
        "ro.debuggable", "ro.secure", "ro.adb.secure", "ro.boot.verifiedbootstate",
        "ro.boot.flash.locked", "ro.boot.vbmeta.device_state", "ro.build.selinux",
    ]

    public var schema: Int
    public var id: String
    public var name: String
    public var properties: [String: String]
    public var display: Display?
    public var notes: String?

    public init(schema: Int = 1, id: String, name: String, properties: [String: String],
                display: Display? = nil, notes: String? = nil) {
        self.schema = schema
        self.id = id
        self.name = name
        self.properties = properties
        self.display = display
        self.notes = notes
    }

    public var brand: String? { properties["ro.product.brand"] }
    public var model: String? { properties["ro.product.model"] }

    /// Problems that make the template unusable.
    public func validate() -> [String] {
        var problems: [String] = []
        if schema != 1 { problems.append("unsupported schema \(schema)") }
        if id.isEmpty || id.contains(where: { !($0.isLetter || $0.isNumber || $0 == "-") }) {
            problems.append("id must contain only letters, digits and '-'")
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("name is empty") }
        // The default profile keeps the image's own identity and overrides nothing.
        let required = id == Self.defaultID && properties.isEmpty ? [] : Self.requiredProperties
        for key in required where (properties[key] ?? "").isEmpty {
            problems.append("missing \(key)")
        }
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            if Self.forbiddenProperties.contains(key) {
                problems.append("\(key) may not be overridden")
            } else if !Self.allowedPropertyPrefixes.contains(where: { key.hasPrefix($0) }) {
                problems.append("\(key) is not an identity property")
            }
            // Property values are limited to 91 bytes (PROP_VALUE_MAX - 1) for non-ro props;
            // ro.* may be longer but must stay on one line.
            if value.contains(where: \.isNewline) { problems.append("\(key) contains a newline") }
        }
        if let fingerprint = properties["ro.build.fingerprint"], !Self.isValidFingerprint(fingerprint) {
            problems.append("ro.build.fingerprint must look like brand/product/device:release/id/incremental:type/tags")
        }
        if let display {
            if display.width < 240 || display.height < 240 { problems.append("display is too small") }
            if !VMConfig.dpiRange.contains(display.dpi) { problems.append("display dpi out of range") }
        }
        return problems
    }

    /// `brand/product/device:release/id/incremental:type/tags`
    public static func isValidFingerprint(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        let head = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        let middle = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        let tail = parts[2].split(separator: "/", omittingEmptySubsequences: false)
        return head.count == 3 && middle.count == 3 && tail.count == 2
            && (head + middle + tail).allSatisfy { !$0.isEmpty && !$0.contains(" ") }
    }

    /// Property file applied by the guest at boot (`key=value` lines, sorted).
    public func propertyFile() -> String {
        properties.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)\n" }.joined()
    }
}

/// Loads templates from a directory of JSON files.
public struct DeviceProfileCatalog: Sendable {
    public private(set) var profiles: [DeviceProfile]
    public private(set) var rejected: [(file: String, problems: [String])]

    public init(profiles: [DeviceProfile]) {
        self.profiles = profiles
        self.rejected = []
    }

    public init(directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var profiles: [DeviceProfile] = []
        var rejected: [(String, [String])] = []
        let decoder = JSONDecoder()
        for file in files {
            do {
                let profile = try decoder.decode(DeviceProfile.self, from: Data(contentsOf: file))
                let problems = profile.validate()
                if problems.isEmpty, file.deletingPathExtension().lastPathComponent == profile.id {
                    profiles.append(profile)
                } else {
                    rejected.append((file.lastPathComponent, problems.isEmpty ? ["file name must match id"] : problems))
                }
            } catch {
                rejected.append((file.lastPathComponent, ["invalid JSON: \(error.localizedDescription)"]))
            }
        }
        // The honest default first, then alphabetical by name.
        self.profiles = profiles.sorted {
            if $0.id == DeviceProfile.defaultID { return true }
            if $1.id == DeviceProfile.defaultID { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        self.rejected = rejected
    }

    public func profile(id: String) -> DeviceProfile? {
        profiles.first { $0.id == id }
    }
}
