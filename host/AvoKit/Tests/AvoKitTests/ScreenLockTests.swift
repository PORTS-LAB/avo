import Foundation
import Testing
@testable import AvoKit

@Suite struct ScreenLockTests {
    /// Android's pattern view adds the dot a straight line passes over.
    @Test func patternsFillInTheDotsALinePassesOver() {
        func draw(_ dots: [Int]) -> [Int] { dots.reduce(into: []) { $0 = AndroidScreenLock.pattern($0, adding: $1) } }
        #expect(draw([1, 3]) == [1, 2, 3])                 // a row
        #expect(draw([1, 7]) == [1, 4, 7])                 // a column
        #expect(draw([1, 9]) == [1, 5, 9])                 // a diagonal
        #expect(draw([3, 7]) == [3, 5, 7])
        #expect(draw([2, 8]) == [2, 5, 8])
        #expect(draw([4, 6]) == [4, 5, 6])
        #expect(draw([1, 8]) == [1, 8])                    // a knight's move passes no dot
        #expect(draw([1, 6]) == [1, 6])
        #expect(draw([5, 1, 9]) == [5, 1, 9])              // the middle is taken already
        #expect(draw([2, 1, 3]) == [2, 1, 3])
        #expect(draw([1, 2, 1, 2]) == [1, 2])              // a dot joins once
        #expect(draw([0, 10, 4]) == [4])                   // only dots 1–9
        #expect(AndroidScreenLock.patternText([1, 2, 3, 5, 7, 8, 9]) == "1235789")
    }

    @Test func credentialsAreCheckedForTheirForm() {
        let pattern = AndroidScreenLock.Credential.pattern
        #expect(pattern.accepts("1235789"))
        #expect(pattern.accepts("2468"))
        #expect(!pattern.accepts("123"))                   // fewer than 4 dots
        #expect(!pattern.accepts("1231"))                  // a dot twice
        #expect(!pattern.accepts("1230"))                  // no dot 0
        #expect(!pattern.accepts("12a4"))
        #expect(!pattern.accepts("1\u{0301}234"))          // a digit with a combining mark

        let pin = AndroidScreenLock.Credential.pin
        #expect(pin.accepts("0000"))
        #expect(pin.accepts("1234567890123456"))
        #expect(!pin.accepts("123"))
        #expect(!pin.accepts("12 34"))
        #expect(!pin.accepts("١٢٣٤"))                      // other scripts' digits are not Android's PIN digits
        #expect(!pin.accepts(String(repeating: "1", count: 65)))

        let password = AndroidScreenLock.Credential.password
        #expect(password.accepts(#"ab'c d%se"f$g"#))       // anything that can be typed
        #expect(password.accepts("kata sandi ✓"))
        #expect(!password.accepts(""))
        #expect(!password.accepts("line\nbreak"))
        #expect(!password.accepts("nul\u{0}"))
        #expect(!password.accepts("tab\t"))
    }

    /// A credential never shows in a description, a debug dump or a mirror.
    @Test func credentialsStayOutOfLogs() throws {
        let secret = "s3cret-Avo!"
        let credential = try #require(ScreenLockCredential(secret, kind: .password))
        #expect(credential.value == secret)
        #expect(!String(describing: credential).contains(secret))
        #expect(!String(reflecting: credential).contains(secret))
        #expect(!"\(credential)".contains(secret))
        var dumped = ""
        dump(credential, to: &dumped)
        #expect(!dumped.contains(secret))
        #expect(!Mirror(reflecting: credential).children.contains { "\($0.value)".contains(secret) })
        #expect(ScreenLockCredential("12", kind: .pattern) == nil)
    }

    /// The status carries the lock; older daemons' statuses (without it) still decode.
    @Test func statusCarriesTheScreenLock() throws {
        let status = VMStatus(state: .running, screenLock: AndroidScreenLock(credential: .pattern))
        let decoded = try AvoXPC.decode(VMStatus.self, from: AvoXPC.encode(status))
        #expect(decoded == status)
        #expect(decoded.screenLock?.credential == .pattern)
        let old = try AvoXPC.decode(VMStatus.self, from: Data(#"{"state":"running","openDisplays":0}"#.utf8))
        #expect(old.screenLock == nil)
        #expect(try AvoXPC.decode(AvoError.self, from: AvoXPC.encode(AvoError.screenLockRejected(throttled: true)))
                == .screenLockRejected(throttled: true))
        #expect(AvoError.androidLocked.errorDescription?.isEmpty == false)
    }
}
