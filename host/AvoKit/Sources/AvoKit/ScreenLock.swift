import Foundation

/// Android's screen lock while it keeps Android locked (`VMStatus.screenLock`).
///
/// Android started with a screen lock keeps its apps' storage encrypted, and
/// its lock screen over every display (Avo's app windows included), until
/// the credential is entered. Avo asks for it (the Control Panel's unlock
/// sheet, the lock over each app window) and passes it to Android, which
/// decides whether it is right. Changing or removing the screen lock is done
/// in Android's own Settings app.
public struct AndroidScreenLock: Codable, Equatable, Sendable {
    /// What Android asks for.
    public enum Credential: String, Codable, Sendable, CaseIterable {
        /// Dots joined on a 3 × 3 grid, numbered 1–9 left to right, top to bottom.
        case pattern
        /// Digits.
        case pin
        /// Any text.
        case password
    }

    public var credential: Credential

    public init(credential: Credential) {
        self.credential = credential
    }

    /// `dots` with `dot` added the way Android's pattern view adds it: a free
    /// dot the line passes straight over (the middle of a row, a column or a
    /// diagonal) joins first. A dot already in the pattern is not added again.
    public static func pattern(_ dots: [Int], adding dot: Int) -> [Int] {
        guard (1...9).contains(dot), !dots.contains(dot) else { return dots }
        var result = dots
        if let last = dots.last {
            let (row, column) = ((last - 1) / 3, (last - 1) % 3)
            let (rowStep, columnStep) = ((dot - 1) / 3 - row, (dot - 1) % 3 - column)
            // LockPatternView.detectAndAddHit: two cells apart in a straight line.
            let middleRow = abs(rowStep) == 2 && abs(columnStep) != 1 ? row + rowStep / 2 : row
            let middleColumn = abs(columnStep) == 2 && abs(rowStep) != 1 ? column + columnStep / 2 : column
            let middle = middleRow * 3 + middleColumn + 1
            if !result.contains(middle) { result.append(middle) }
        }
        result.append(dot)
        return result
    }

    /// A pattern as Android's lock settings take it: `[1, 2, 3, 5]` → "1235".
    public static func patternText(_ dots: [Int]) -> String {
        dots.map(String.init).joined()
    }
}

extension AndroidScreenLock.Credential {
    /// Android's shortest pattern (dots) and PIN (digits).
    public static let minimumPatternDots = 4
    public static let minimumPINDigits = 4
    /// Longer than anything Android takes (16 characters), short enough for
    /// a command line.
    public static let maximumLength = 64

    /// Whether `text` has this credential's form, which is checked before it
    /// goes anywhere (Android decides whether it is right): 4–9 different
    /// dots 1–9 for a pattern, 4 or more digits for a PIN, a password without
    /// control characters.
    public func accepts(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= Self.maximumLength else { return false }
        switch self {
        case .pattern:
            let dots = text.compactMap(\.asciiValue)
            return dots.count == text.count && dots.count >= Self.minimumPatternDots && Set(dots).count == dots.count
                && dots.allSatisfy { (UInt8(ascii: "1")...UInt8(ascii: "9")).contains($0) }
        case .pin:
            let digits = text.compactMap(\.asciiValue)
            return digits.count == text.count && digits.count >= Self.minimumPINDigits
                && digits.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        case .password:
            // Newlines and other control characters cannot be typed on Android's lock screen.
            return !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
    }
}

/// A screen lock credential on its way to Android, checked for its kind's
/// form. It never shows in logs or dumps: its descriptions and mirror leave
/// the value out. Nothing keeps it after the unlock.
public struct ScreenLockCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let kind: AndroidScreenLock.Credential
    /// The pattern's dots ("1235789"), the PIN's digits or the password.
    public let value: String

    /// Nil when `value` does not have the form of `kind`.
    public init?(_ value: String, kind: AndroidScreenLock.Credential) {
        guard kind.accepts(value) else { return nil }
        self.kind = kind
        self.value = value
    }

    public var description: String { "ScreenLockCredential(\(kind.rawValue), redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["kind": kind]) }
}
