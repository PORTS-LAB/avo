import Foundation
import Testing
@testable import AvoKeymap

@Suite struct KeymapTemplateTests {
    private let empty = KeymapProfile(package: "com.example.game", name: "Mine", controls: [])

    @Test(arguments: KeymapTemplate.allCases)
    func templatesAreValidProfiles(_ template: KeymapTemplate) throws {
        for aspect in [16.0 / 9.0, 20.0 / 9.0, 4.0 / 3.0] {
            let insertion = template.insert(into: empty, replacing: false, aspect: aspect)
            let profile = insertion.profile
            #expect(profile.validate().isEmpty, "\(template) at \(aspect): \(profile.validate())")
            #expect(insertion.unbound.isEmpty && insertion.skipped.isEmpty)
            #expect(insertion.added == profile.controls.map(\.id))
            // And they survive a save.
            #expect(try KeymapProfile.decode(profile.encoded()) == profile)
        }
    }

    @Test func templatesBringWhatTheirGameNeeds() {
        let fps = KeymapTemplate.fps.layout(aspect: 16.0 / 9.0)
        #expect(fps.fps?.aimControl == "eye")
        #expect(fps.controls.contains { $0.triggers == [.mouse(.left)] && $0.layer == .locked })
        #expect(fps.controls.contains { if case .ads = $0.kind { $0.triggers == [.mouse(.right)] } else { false } })
        for key in [KeyName.space, .c, .r] { #expect(fps.controls.contains { $0.triggers.contains(.key(key)) }) }

        let moba = KeymapTemplate.moba.layout(aspect: 16.0 / 9.0)
        #expect(moba.controls.contains { $0.followsCursor && $0.triggers == [.mouse(.right)] })
        let skills = moba.controls.filter { if case .smartCast = $0.kind { true } else { false } }
        #expect(skills.flatMap(\.triggers) == [.key(.q), .key(.w), .key(.e), .key(.r)])

        let racing = KeymapTemplate.racing.layout(aspect: 16.0 / 9.0)
        for key in [KeyName.a, .d, .w, .s] { #expect(racing.controls.contains { $0.triggers.contains(.key(key)) }) }

        let platformer = KeymapTemplate.platformer.layout(aspect: 16.0 / 9.0)
        #expect(platformer.controls.contains { if case .dpad = $0.kind { true } else { false } })
        for key in [KeyName.space, .j, .k] { #expect(platformer.controls.contains { $0.triggers.contains(.key(key)) }) }
    }

    @Test func replacingSwapsTheLayoutButKeepsTheProfile() {
        var mine = empty
        mine.notes = "my notes"
        mine.controls = [Control(id: "jump", kind: .tap(NormalizedPoint(0.5, 0.5)), triggers: [.key(.space)])]
        let insertion = KeymapTemplate.racing.insert(into: mine, replacing: true, aspect: 16.0 / 9.0)
        #expect(insertion.profile.controls == KeymapTemplate.racing.layout(aspect: 16.0 / 9.0).controls)
        #expect(insertion.profile.notes == "my notes")
        #expect(insertion.profile.package == mine.package)
        // The hero point belongs to the game's camera, not to a layout.
        mine.hero = NormalizedPoint(0.5, 0.58)
        #expect(KeymapTemplate.moba.insert(into: mine, replacing: true, aspect: 16.0 / 9.0).profile.hero == mine.hero)
    }

    @Test func addingNeverChangesTheUsersControls() {
        // The player's own layout: Space and F are taken, and there is a D-pad on WASD.
        let mine = [
            Control(id: "move", kind: .dpad(center: NormalizedPoint(0.2, 0.7), radius: 0.1, up: .key(.w), down: .key(.s),
                                            left: .key(.a), right: .key(.d), stick: nil)),
            Control(id: "attack", kind: .tap(NormalizedPoint(0.6, 0.6)), triggers: [.key(.space)]),
            Control(id: "item", kind: .tap(NormalizedPoint(0.3, 0.2)), triggers: [.key(.f)]),
        ]
        let profile = KeymapProfile(package: "com.example.moba", name: "Mine", controls: mine, hero: NormalizedPoint(0.5, 0.45))
        let insertion = KeymapTemplate.moba.insert(into: profile, replacing: false, aspect: 16.0 / 9.0)
        let result = insertion.profile
        #expect(Array(result.controls.prefix(mine.count)) == mine)
        #expect(result.hero == NormalizedPoint(0.5, 0.45))
        // IDs stay unique: the template's "move" and "attack" are renamed.
        #expect(Set(result.controls.map(\.id)).count == result.controls.count)
        #expect(result.controls.contains { $0.id == "move-2" && $0.followsCursor })
        // Keys already in use (Space, the D-pad's W, F) stay with the player's controls.
        #expect(insertion.unbound == ["attack-2", "skill-2", "spell"])
        #expect(result.controls.first { $0.id == "attack-2" }?.triggers == [])
        #expect(result.controls.first { $0.id == "skill-1" }?.triggers == [.key(.q)])
        #expect(insertion.skipped.isEmpty)
        // Only the unbound controls stop it from saving until they get a key.
        #expect(result.validate().sorted() == ["attack-2: needs a trigger", "skill-2: needs a trigger", "spell: needs a trigger"])
    }

    @Test func addingFPSRespectsTheExistingEyeAndDPad() {
        let eye = Control(id: "camera", kind: .aim(area: NormalizedRect(0.5, 0.1, 1, 0.7), sensitivity: AxisPair(x: 2, y: 2),
                                                   adsSensitivity: AxisPair(x: 1, y: 1), exponent: 1, deadzone: 0, invertY: false,
                                                   stick: nil))
        let dpad = Control(id: "walk", kind: .dpad(center: NormalizedPoint(0.2, 0.7), radius: 0.1, up: .key(.w), down: .key(.s),
                                                   left: .key(.a), right: .key(.d), stick: nil))
        let profile = KeymapProfile(package: "com.example.fps", name: "Mine", controls: [eye, dpad],
                                    fps: FPSSettings(cursorToggle: .key(.option), aimControl: "camera"))
        let insertion = KeymapTemplate.fps.insert(into: profile, replacing: false, aspect: 16.0 / 9.0)
        #expect(insertion.skipped == ["move", "eye"])
        #expect(insertion.profile.fps == profile.fps)
        #expect(insertion.profile.validate().isEmpty)
    }

    @Test func addingFPSPicksAFreeKeyToLockTheMouse() {
        // F8, the usual key, already does something else here.
        let profile = KeymapProfile(package: "com.example.fps", name: "Mine",
                                    controls: [Control(id: "map", kind: .tap(NormalizedPoint(0.9, 0.1)), triggers: [.key(.f8)])])
        let insertion = KeymapTemplate.fps.insert(into: profile, replacing: false, aspect: 16.0 / 9.0)
        #expect(insertion.profile.fps == FPSSettings(cursorToggle: .key(.grave), aimControl: "eye"))
        #expect(insertion.profile.validate().isEmpty)
    }

    @Test func addingHasNoControlLimit() {
        let keys: [KeyName] = [.digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9,
                               .f1, .f2, .f3, .f4]
        let mine = keys.enumerated().map { index, key in
            Control(id: "slot-\(index)", kind: .tap(NormalizedPoint(Double(index) / 20, 0.1)), triggers: [.key(key)])
        }
        let insertion = KeymapTemplate.platformer.insert(into: KeymapProfile(package: "x", name: "x", controls: mine),
                                                         replacing: false, aspect: 16.0 / 9.0)
        // Fourteen of the user's own plus the whole layout: only fingers down at once are limited.
        #expect(insertion.profile.controls.count == keys.count + 4)
        #expect(insertion.added == ["move", "jump", "action-1", "action-2"])
        #expect(insertion.skipped.isEmpty)
        #expect(insertion.profile.validate().isEmpty)
        let forty = KeymapProfile(package: "x", name: "x", controls: (0..<40).map {
            Control(id: "tap-\($0)", kind: .tap(NormalizedPoint(Double($0) / 40, 0.5)), triggers: [])
        })
        #expect(!forty.validate().contains { $0.contains("at most") })
    }
}
