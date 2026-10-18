import AvoProtocol
import Testing
@testable import AvoKeymap

@Suite struct GamepadReadingTests {
    /// The engine's gamepad reads these bits (GAMEPAD_BUTTONS in
    /// engine/hvf/vmm/src/virtio/input.rs): they must not move.
    @Test func buttonBitsMatchTheEngine() {
        let bits: [GamepadButton: UInt32] = [
            .a: 0, .b: 1, .x: 2, .y: 3, .leftShoulder: 4, .rightShoulder: 5,
            .leftThumbstick: 12, .rightThumbstick: 13, .menu: 14, .options: 15,
        ]
        for (button, bit) in bits { #expect(button.bit == 1 << bit, "\(button)") }
        #expect(GamepadButton.allCases.count == 16)
        #expect(GamepadReading.homeBit == 1 << 16)
    }

    @Test func buttonsSticksAndTriggersCarryOver() {
        let reading = GamepadReading(pressed: [.a, .menu, .leftTrigger], home: true, leftX: 0.25, leftY: -0.5,
                                     rightX: 1, rightY: 0.75, leftTrigger: 0.6, rightTrigger: 0)
        let state = reading.state(pad: 1)
        #expect(state.pad == 1)
        #expect(state.connected)
        #expect(state.buttons == GamepadButton.a.bit | GamepadButton.menu.bit | GamepadButton.leftTrigger.bit | GamepadReading.homeBit)
        #expect(state.axes == [0.25, -0.5, 1, 0.75, 0.6, 0, 0, 0])
    }

    @Test func dpadIsAlsoTheHatWithYUp() {
        #expect(GamepadReading(pressed: [.dpadUp, .dpadLeft]).state()[.hatX] == -1)
        #expect(GamepadReading(pressed: [.dpadUp, .dpadLeft]).state()[.hatY] == 1)
        #expect(GamepadReading(pressed: [.dpadDown, .dpadRight]).state()[.hatY] == -1)
        let both = GamepadReading(pressed: [.dpadLeft, .dpadRight]).state()
        #expect(both[.hatX] == 0, "opposite directions cancel out")
    }

    @Test func valuesAreClampedAndNaNIsRest() {
        let state = GamepadReading(leftX: 3, leftY: .nan, rightX: -2, leftTrigger: -0.5, rightTrigger: 1.5).state()
        #expect(state.axes == [1, 0, -1, 0, 0, 1, 0, 0])
    }

    @Test func aProfileUsesTheGamepadWhenAControlOrTheCursorToggleIsOnIt() {
        let tap = Control(id: "jump", kind: .tap(NormalizedPoint(0.9, 0.7)), triggers: [.key(.space)])
        let profile = { (controls: [Control], fps: FPSSettings?) in
            KeymapProfile(package: "com.example.game", name: "Test", controls: controls, fps: fps)
        }
        #expect(!profile([tap], nil).usesGamepad)

        let padTap = Control(id: "fire", kind: .tap(NormalizedPoint(0.8, 0.7)), triggers: [.gamepad(.rightTrigger)])
        #expect(profile([tap, padTap], nil).usesGamepad)

        let stick = Control(id: "move", kind: .dpad(center: NormalizedPoint(0.2, 0.7), radius: 0.1, up: .key(.w), down: .key(.s),
                                                      left: .key(.a), right: .key(.d), stick: .left), triggers: [])
        #expect(profile([stick], nil).usesGamepad)

        let toggle = FPSSettings(cursorToggle: .gamepad(.options), aimControl: "jump")
        #expect(profile([tap], toggle).usesGamepad)
    }
}
