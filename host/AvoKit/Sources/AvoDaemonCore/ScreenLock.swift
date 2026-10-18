import AvoKit
import Foundation

/// An engine whose Android Avo can unlock with its screen lock's credential
/// (HostAgent's "Screen lock").
public protocol ScreenLockEngine: VMEngine {
    /// Android's screen lock while it keeps Android locked, nil when it does
    /// not: reported at every start, then whenever it changes.
    var screenLockUpdates: AsyncStream<AndroidScreenLock?> { get }
    /// The state now, straight from the guest (nil while Android is not ready).
    func screenLock() async -> AndroidScreenLock?
    /// Passes the credential to Android and returns once Android is unlocked;
    /// throws `AvoError.screenLockRejected` when Android does not take it.
    func unlockScreen(_ credential: ScreenLockCredential) async throws
}

/// Android's screen lock as its shell shows it (HostAgent): the queries and
/// what they print, and the commands that pass the credential on.
///
/// Android started with a screen lock keeps user 0's credential-encrypted
/// storage closed (apps other than direct-boot-aware ones neither resolve
/// nor start) and its lock screen up over every display, app windows
/// included. `cmd lock_settings verify` opens the storage but leaves the lock
/// screen; its bouncer on Android's own screen (display 0) takes the
/// credential as a person would enter it.
enum GuestScreenLock {
    // MARK: State

    /// User 0's state in one round trip: its storage (vold's property and
    /// ActivityManager's user state) and whether the lock screen holds the
    /// device (TrustManager: secure and showing).
    static let stateCommand = "echo ce=$(getprop sys.user.0.ce_available); echo user=$(am get-started-user-state 0); "
        + "dumpsys trust | grep -m 1 '(id=0,'"

    struct State: Equatable {
        /// User 0's storage is still closed; nil when the output says nothing usable.
        var storageLocked: Bool?
        /// The lock screen holds the device; nil when unknown.
        var keyguardLocked: Bool?

        /// Apps can neither start nor show: the storage, or the lock screen over every display.
        var locked: Bool { storageLocked == true || keyguardLocked == true }
    }

    /// `ce=true` (or empty), `user=RUNNING_LOCKED` (RUNNING_UNLOCKING,
    /// RUNNING_UNLOCKED) and TrustManager's line for user 0
    /// (`User "Owner" (id=0, flags=0xc13) (current): trusted=0, trustManaged=0, deviceLocked=1, …`).
    static func state(_ output: String) -> State {
        var state = State()
        for line in output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("ce=") {
                if line == "ce=true" { state.storageLocked = false }
            } else if line.hasPrefix("user=") {
                // The storage's own property wins: ActivityManager follows it.
                guard state.storageLocked == nil else { continue }
                if line.contains("RUNNING_UNLOCKED") || line.contains("RUNNING_UNLOCKING") {
                    state.storageLocked = false
                } else if line.contains("RUNNING_LOCKED") || line.contains("BOOTING") {
                    state.storageLocked = true
                }
            } else if let range = line.range(of: "deviceLocked=") {
                switch line[range.upperBound...].prefix(while: { $0.isLetter || $0.isNumber }) {
                case "1", "true": state.keyguardLocked = true
                case "0", "false": state.keyguardLocked = false
                default: break
                }
            }
        }
        return state
    }

    /// What user 0's screen lock asks for.
    static let credentialCommand = "dumpsys lock_settings"

    /// `dumpsys lock_settings`: `CredentialType: PATTERN` (NONE, PIN,
    /// PASSWORD, PASSWORD_OR_PIN) in the `User 0` block; nil for none.
    static func credential(dumpsys output: String) -> AndroidScreenLock.Credential? {
        var user: Int?
        var sawUser = false
        for line in output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("User "), let id = Int(line.dropFirst("User ".count)) {
                user = id
                sawUser = true
            } else if line.hasPrefix("CredentialType:"), user == 0 || !sawUser {
                switch line.dropFirst("CredentialType:".count).trimmingCharacters(in: .whitespaces) {
                case "NONE", "": return nil
                case "PATTERN": return .pattern
                case "PIN": return .pin
                // PASSWORD, PASSWORD_OR_PIN (Android asks by the stored quality),
                // and kinds this version does not know: typed text.
                default: return .password
                }
            }
        }
        return nil
    }

    // MARK: Unlocking

    /// Checks the credential; when it is right, Android opens user 0's storage.
    static func verifyCommand(_ credential: ScreenLockCredential) -> String {
        "cmd lock_settings verify --old " + HostAgent.quote(credential.value)
    }

    enum Outcome: Equatable {
        case verified
        case wrong
        /// Too many wrong ones: Android takes none for a while (about a minute).
        case throttled
        /// Android has no screen lock (any more).
        case noLock
        case failed
    }

    /// What `cmd lock_settings verify` said. Its output repeats a wrong
    /// credential (`Old password '…' didn't match`): it is read here, never
    /// logged or passed on.
    static func outcome(exitCode: Int32, output: String) -> Outcome {
        if exitCode == 0, output.contains("verified successfully") { return .verified }
        if output.contains("Request throttled") { return .throttled }
        if output.contains("didn't match") { return .wrong }
        if output.contains("user has no password") { return .noLock }
        return .failed
    }

    // MARK: The lock screen's bouncer (display 0)

    struct Frame: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    /// The bouncer showing on Android's own screen.
    enum Bouncer: Equatable {
        /// The pattern grid, in display 0's pixels.
        case pattern(Frame)
        case pin
        case password

        /// Whether it is the bouncer for this kind of credential.
        func takes(_ kind: AndroidScreenLock.Credential) -> Bool {
            switch (self, kind) {
            case (.pattern, .pattern), (.pin, .pin), (.password, .password): true
            default: false
            }
        }
    }

    /// Display 0's window hierarchy (SystemUI's keyguard while it shows).
    static let dumpCommand = "uiautomator dump /data/local/tmp/avo-keyguard.xml >/dev/null 2>&1; "
        + "cat /data/local/tmp/avo-keyguard.xml 2>/dev/null; rm -f /data/local/tmp/avo-keyguard.xml"

    /// SystemUI's bouncer views in a `uiautomator dump`: the pattern grid
    /// (with its bounds), the PIN entry or the password field. Nil when none
    /// shows: nothing is ever typed into anything else on display 0.
    static func bouncer(inDump xml: String) -> Bouncer? {
        var found: Bouncer?
        for node in xml.components(separatedBy: "<node ").dropFirst() {
            switch attribute("resource-id", in: node) {
            case "com.android.systemui:id/lockPatternView":
                if let frame = bounds(attribute("bounds", in: node)) { return .pattern(frame) }
            case "com.android.systemui:id/pinEntry", "com.android.systemui:id/keyguard_pin_view":
                found = found ?? .pin
            case "com.android.systemui:id/passwordEntry", "com.android.systemui:id/keyguard_password_view":
                found = found ?? .password
            default:
                break
            }
        }
        return found
    }

    private static func attribute(_ name: String, in node: String) -> String? {
        guard let start = node.range(of: " \(name)=\"") ?? (node.hasPrefix("\(name)=\"") ? node.range(of: "\(name)=\"") : nil),
              let end = node[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(node[start.upperBound..<end])
    }

    /// `[12,292][708,988]`.
    private static func bounds(_ text: String?) -> Frame? {
        guard let text else { return nil }
        let numbers = text.split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Int($0) }
        guard numbers.count == 4, numbers[2] > numbers[0], numbers[3] > numbers[1] else { return nil }
        return Frame(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
    }

    /// Draws the pattern on the bouncer's grid as a finger does: down on the
    /// first dot, through each of the others, up on the last.
    static func patternCommand(_ dots: String, in frame: Frame) -> String {
        let points = dots.compactMap(\.wholeNumberValue).filter { (1...9).contains($0) }.map { dot in
            let (row, column) = ((dot - 1) / 3, (dot - 1) % 3)
            return (x: frame.x + frame.width * (2 * column + 1) / 6, y: frame.y + frame.height * (2 * row + 1) / 6)
        }
        guard let first = points.first, let last = points.last else { return "" }
        let steps = ["DOWN \(first.x) \(first.y)"] + points.dropFirst().map { "MOVE \($0.x) \($0.y)" } + ["UP \(last.x) \(last.y)"]
        return steps.map { "input -d 0 motionevent " + $0 }.joined(separator: " && ")
    }

    /// Types a PIN or password into the bouncer's field (then Enter).
    /// `input text` turns "%s" into a space, so the text goes in pieces that
    /// each end at a "%".
    static func typingCommand(_ text: String, enter: Bool) -> String {
        var pieces: [String] = []
        var piece = ""
        for character in text {
            piece.append(character)
            if character == "%" {
                pieces.append(piece)
                piece = ""
            }
        }
        if !piece.isEmpty { pieces.append(piece) }
        let commands = pieces.map { "input -d 0 text " + HostAgent.quote($0) } + (enter ? [enterCommand] : [])
        return commands.joined(separator: " && ")
    }

    static let enterCommand = "input -d 0 keyevent 66"

    /// Shows the bouncer (on display 0) when the lock screen is secure, or
    /// dismisses a lock screen without a credential.
    static let dismissCommand = "wm dismiss-keyguard"
}
