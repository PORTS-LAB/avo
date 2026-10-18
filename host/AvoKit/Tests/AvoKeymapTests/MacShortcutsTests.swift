import Testing
@testable import AvoKeymap

@Suite struct MacShortcutsTests {
    private func presses(_ key: KeyName, command: Bool = false, option: Bool = false, shift: Bool = false,
                         control: Bool = false) -> [MacShortcuts.Press]? {
        MacShortcuts.presses(for: key, command: command, option: option, shift: shift, control: control)
    }

    @Test func commandLettersAreControlLetters() {
        #expect(presses(.c, command: true) == [.init(keyCode: 31, metaState: MacShortcuts.ctrl)])
        #expect(presses(.v, command: true) == [.init(keyCode: 50, metaState: MacShortcuts.ctrl)])
        #expect(presses(.a, command: true) == [.init(keyCode: 29, metaState: MacShortcuts.ctrl)])
        // ⌘⇧Z is redo: Ctrl+Shift+Z.
        #expect(presses(.z, command: true, shift: true) == [.init(keyCode: 54, metaState: MacShortcuts.ctrl | MacShortcuts.shift)])
        #expect(presses(.t, command: true) == [.init(keyCode: 48, metaState: MacShortcuts.ctrl)])
    }

    @Test func windowShortcutsStayWithTheWindow() {
        for key in MacShortcuts.windowKeys { #expect(presses(key, command: true) == nil) }
        #expect(presses(.k, command: true, shift: true) == nil) // key mapping editor
        #expect(presses(.space, command: true) == nil)
    }

    @Test func captureShortcutsStayWithTheWindow() {
        for key in MacShortcuts.windowShiftKeys { #expect(presses(key, command: true, shift: true) == nil) }
        #expect(presses(.s, command: true, shift: true) == nil) // Take Screenshot
        #expect(presses(.r, command: true, shift: true) == nil) // Record Screen
        #expect(presses(.t, command: true, shift: true) == nil) // Translate Screen
        // Only with ⇧: ⌘S is still Ctrl+S, ⌘K Ctrl+K and ⌘T Ctrl+T for the app.
        #expect(presses(.s, command: true) == [.init(keyCode: 47, metaState: MacShortcuts.ctrl)])
        #expect(presses(.k, command: true) == [.init(keyCode: 39, metaState: MacShortcuts.ctrl)])
        #expect(presses(.t, command: true) == [.init(keyCode: 48, metaState: MacShortcuts.ctrl)])
        #expect(presses(.s, command: true, option: true, shift: true) == nil)
    }

    @Test func linesAndWordsMoveAndDeleteLikeOnAMac() {
        #expect(presses(.left, command: true) == [.init(keyCode: 122)])
        #expect(presses(.right, command: true, shift: true) == [.init(keyCode: 123, metaState: MacShortcuts.shift)])
        #expect(presses(.up, command: true) == [.init(keyCode: 122, metaState: MacShortcuts.ctrl)])
        #expect(presses(.left, option: true) == [.init(keyCode: 21, metaState: MacShortcuts.ctrl)])
        #expect(presses(.delete, option: true) == [.init(keyCode: 67, metaState: MacShortcuts.ctrl)])
        #expect(presses(.delete, command: true) == [.init(keyCode: 122, metaState: MacShortcuts.shift), .init(keyCode: 67)])
        #expect(presses(.leftBracket, command: true) == [.init(keyCode: 4)])
    }

    @Test func controlAndPlainKeysAreNotTranslated() {
        #expect(presses(.c, control: true) == nil)
        #expect(presses(.c) == nil)
        #expect(presses(.e, option: true) == nil) // ⌥E is a dead key for accents
    }
}
