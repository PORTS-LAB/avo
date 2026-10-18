import Foundation

/// Mac editing and app shortcuts as Android key presses. On the Mac, ⌘ is
/// what Ctrl is on Android (copy, paste, undo, find, new tab, …), ⌘ and ⌥
/// with the arrows and Delete move and delete by line and by word, and
/// Control combinations reach Android as they are.
public enum MacShortcuts {
    /// One Android key press, with its META_* state.
    public struct Press: Equatable, Sendable {
        public var keyCode: UInt32
        public var metaState: UInt32

        public init(keyCode: UInt32, metaState: UInt32 = 0) {
            self.keyCode = keyCode
            self.metaState = metaState
        }
    }

    public static let ctrl: UInt32 = 0x1000 | 0x2000   // META_CTRL_ON | META_CTRL_LEFT_ON
    public static let shift: UInt32 = 0x01 | 0x40      // META_SHIFT_ON | META_SHIFT_LEFT_ON

    /// ⌘ shortcuts an app window keeps for itself: Quit, Close Window, Hide,
    /// Minimize, New Window, Game Mode, Rotate.
    public static let windowKeys: Set<KeyName> = [.q, .w, .h, .m, .n, .g, .r]

    /// ⌘⇧ shortcuts an app window keeps for itself: the key mapping editor
    /// (⌘⇧K), Take Screenshot (⌘⇧S), Record Screen (⌘⇧R) and Translate
    /// Screen (⌘⇧T). Without ⇧ they still reach Android (⌘S is Ctrl+S,
    /// save; ⌘T is Ctrl+T, new tab).
    public static let windowShiftKeys: Set<KeyName> = [.k, .s, .r, .t]

    private enum Code {
        static let back: UInt32 = 4, dpadLeft: UInt32 = 21, dpadRight: UInt32 = 22
        static let del: UInt32 = 67, forwardDel: UInt32 = 112, moveHome: UInt32 = 122, moveEnd: UInt32 = 123
        static let forward: UInt32 = 125
    }

    /// The presses for `key` with these modifiers, or nil when it is not a
    /// shortcut to translate (typed text, a window shortcut, or a key the
    /// caller sends as it is).
    public static func presses(for key: KeyName, command: Bool, option: Bool, shift held: Bool, control: Bool) -> [Press]? {
        guard !control, !key.isModifier else { return nil }
        let selecting = held ? shift : 0
        if command, !option {
            switch key {
            case .left: return [Press(keyCode: Code.moveHome, metaState: selecting)]
            case .right: return [Press(keyCode: Code.moveEnd, metaState: selecting)]
            case .up: return [Press(keyCode: Code.moveHome, metaState: ctrl | selecting)]
            case .down: return [Press(keyCode: Code.moveEnd, metaState: ctrl | selecting)]
            // Delete to the start or end of the line: select it, then delete.
            case .delete: return [Press(keyCode: Code.moveHome, metaState: shift), Press(keyCode: Code.del)]
            case .forwardDelete: return [Press(keyCode: Code.moveEnd, metaState: shift), Press(keyCode: Code.forwardDel)]
            case .leftBracket: return [Press(keyCode: Code.back)]
            case .rightBracket: return [Press(keyCode: Code.forward)]
            case .escape, .tab, .space: return nil
            default:
                guard !windowKeys.contains(key), !(held && windowShiftKeys.contains(key)),
                      let code = KeyboardMapping.androidKeyCode(for: key) else { return nil }
                return [Press(keyCode: code, metaState: ctrl | selecting)]   // ⌘⇧Z is Ctrl+Shift+Z, redo
            }
        }
        if option, !command {
            switch key {
            case .left: return [Press(keyCode: Code.dpadLeft, metaState: ctrl | selecting)]
            case .right: return [Press(keyCode: Code.dpadRight, metaState: ctrl | selecting)]
            case .delete: return [Press(keyCode: Code.del, metaState: ctrl)]
            case .forwardDelete: return [Press(keyCode: Code.forwardDel, metaState: ctrl)]
            default: return nil   // ⌥ letters type special characters through the input method
            }
        }
        return nil
    }
}
