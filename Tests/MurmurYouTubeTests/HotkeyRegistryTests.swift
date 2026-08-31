import Foundation
import CoreGraphics
import Testing
@testable import MurmurYouTube

@Suite("Typed hotkey registry")
struct HotkeyRegistryTests {
    @Test("legacy presets migrate without changing their physical key")
    func presetMigration() {
        let fn = PushToTalkKey.fn.binding(gesture: .hold)
        let command = PushToTalkKey.rightCommand.binding(gesture: .toggle)

        #expect(fn.keyCode == 63)
        #expect(fn.consumption == .observe)
        #expect(fn.gesture == .hold)
        #expect(command.keyCode == 54)
        #expect(command.consumption == .suppress)
        #expect(command.gesture == .toggle)
    }

    @Test("typed bindings survive a JSON round trip")
    func codable() throws {
        let binding = HotkeyBinding(
            keyCode: 49,
            requiredFlags: HotkeyModifier.command.rawValue | HotkeyModifier.shift.rawValue,
            side: nil,
            gesture: .doubleTapHold,
            consumption: .suppress,
            label: "⇧⌘Space"
        )

        let restored = try JSONDecoder().decode(
            HotkeyBinding.self,
            from: JSONEncoder().encode(binding)
        )
        #expect(restored == binding)
    }

    @Test("duplicate shortcuts are rejected")
    func duplicate() {
        let binding = PushToTalkKey.rightCommand.binding(gesture: .hold)
        let issues = HotkeyBindingValidator.validate(primary: binding, handsFree: binding)

        #expect(issues.contains { $0.code == .duplicate && $0.severity == .error })
    }

    @Test("Command Mode has a distinct safe default")
    func commandDefault() {
        let command = HotkeyBinding.commandModeDefault
        let registry = HotkeyBindingRegistry(
            pushToTalk: PushToTalkKey.fn.binding(gesture: .hold),
            handsFree: PushToTalkKey.rightCommand.binding(gesture: .toggle),
            commandMode: command
        )

        #expect(command.label == "⌃⌥⌘D")
        #expect(command.gesture == .hold)
        #expect(Set([registry.pushToTalk.id, registry.handsFree.id, registry.commandMode.id]).count == 3)
    }

    @Test("Command Mode cannot duplicate either dictation shortcut")
    func commandDuplicate() {
        let primary = PushToTalkKey.fn.binding(gesture: .hold)
        let issues = HotkeyBindingValidator.validate(
            primary: primary,
            handsFree: PushToTalkKey.rightCommand.binding(gesture: .toggle),
            commandMode: primary
        )
        #expect(issues.contains { $0.code == .duplicate && $0.severity == .error })
    }

    @Test("bare ordinary keys are rejected")
    func bareKey() {
        let binding = HotkeyBinding(
            keyCode: 0,
            requiredFlags: 0,
            side: nil,
            gesture: .hold,
            consumption: .suppress,
            label: "A"
        )

        #expect(HotkeyBindingValidator.issues(for: binding).contains {
            $0.code == .bareKey && $0.severity == .error
        })
    }

    @Test("reserved macOS shortcuts are rejected")
    func reserved() {
        let quit = HotkeyBinding(
            keyCode: 12,
            requiredFlags: HotkeyModifier.command.rawValue,
            side: nil,
            gesture: .hold,
            consumption: .suppress,
            label: "⌘Q"
        )

        #expect(HotkeyBindingValidator.issues(for: quit).contains {
            $0.code == .systemReserved && $0.severity == .error
        })
    }

    @Test("Right Option exposes the international-layout risk")
    func rightOptionWarning() {
        let issues = HotkeyBindingValidator.issues(
            for: PushToTalkKey.rightOption.binding(gesture: .hold)
        )
        #expect(issues.contains { $0.code == .internationalLayout && $0.severity == .warning })
    }
}

@Suite("Hotkey event routing")
struct HotkeyEventRouterTests {
    @Test("a custom chord consumes press, repeat, and release but emits one edge each")
    func customChord() {
        let binding = HotkeyBinding(
            keyCode: 49,
            requiredFlags: HotkeyModifier.command.rawValue | HotkeyModifier.shift.rawValue,
            side: nil,
            gesture: .hold,
            consumption: .suppress,
            label: "⇧⌘Space"
        )
        let flags = CGEventFlags(rawValue: binding.requiredFlags)
        let router = HotkeyEventRouter()
        router.configure(binding: binding, handsFreeBinding: nil, handsFreeSessionIsActive: false)

        let press = router.route(type: .keyDown, keyCode: 49, flags: flags)
        let repeated = router.route(type: .keyDown, keyCode: 49, flags: flags)
        let release = router.route(type: .keyUp, keyCode: 49, flags: flags)

        #expect(press.consume && press.action == .press)
        #expect(repeated.consume && repeated.action == nil)
        #expect(release.consume && release.action == .release)
    }

    @Test("an observed fn binding triggers without swallowing the event")
    func observedModifier() {
        let binding = PushToTalkKey.fn.binding(gesture: .hold)
        let router = HotkeyEventRouter()
        router.configure(binding: binding, handsFreeBinding: nil, handsFreeSessionIsActive: false)

        let result = router.route(
            type: .flagsChanged,
            keyCode: binding.keyCode,
            flags: CGEventFlags(rawValue: binding.requiredFlags)
        )

        #expect(!result.consume)
        #expect(result.action == .press)
    }

    @Test("Return is consumed only while hands-free is active")
    func handsFreeControl() {
        let router = HotkeyEventRouter()
        router.configure(
            binding: PushToTalkKey.fn.binding(gesture: .hold),
            handsFreeBinding: PushToTalkKey.rightCommand.binding(gesture: .toggle),
            handsFreeSessionIsActive: false
        )

        let inactive = router.route(type: .keyDown, keyCode: 36, flags: [])
        router.handsFreeSessionIsActive = true
        let active = router.route(type: .keyDown, keyCode: 36, flags: [])

        #expect(!inactive.consume && inactive.action == nil)
        #expect(active.consume && active.action == .handsFreeFinish)
    }

    @Test("the Command Mode chord emits dedicated hold edges")
    func commandModeChord() {
        let binding = HotkeyBinding.commandModeDefault
        let flags = CGEventFlags(rawValue: binding.requiredFlags)
        let router = HotkeyEventRouter()
        router.configure(
            binding: PushToTalkKey.fn.binding(gesture: .hold),
            handsFreeBinding: nil,
            commandModeBinding: binding,
            handsFreeSessionIsActive: false
        )

        let press = router.route(type: .keyDown, keyCode: binding.keyCode, flags: flags)
        let release = router.route(type: .keyUp, keyCode: binding.keyCode, flags: flags)

        #expect(press.consume && press.action == .commandModePress)
        #expect(release.consume && release.action == .commandModeRelease)
    }
}

@Suite("Hotkey gesture policy")
struct HotkeyGesturePolicyTests {
    @Test("hold follows press and release edges")
    func hold() {
        var policy = HotkeyGesturePolicy(gesture: .hold)
        #expect(policy.handle(.pressed(at: 1)) == .start)
        #expect(policy.handle(.pressed(at: 1.1)) == .ignore)
        #expect(policy.handle(.released(at: 2)) == .finish)
    }

    @Test("toggle ignores release and finishes on the next press")
    func toggle() {
        var policy = HotkeyGesturePolicy(gesture: .toggle)
        #expect(policy.handle(.pressed(at: 1)) == .start)
        #expect(policy.handle(.released(at: 1.1)) == .ignore)
        #expect(policy.handle(.pressed(at: 2)) == .finish)
    }

    @Test("double tap and hold starts only on a timely second press")
    func doubleTapHold() {
        var policy = HotkeyGesturePolicy(gesture: .doubleTapHold, doubleTapWindow: 0.4)
        #expect(policy.handle(.pressed(at: 1)) == .ignore)
        #expect(policy.handle(.released(at: 1.05)) == .ignore)
        #expect(policy.handle(.pressed(at: 1.3)) == .start)
        #expect(policy.handle(.released(at: 2)) == .finish)
    }

    @Test("a late second tap starts a new waiting window")
    func lateSecondTap() {
        var policy = HotkeyGesturePolicy(gesture: .doubleTapHold, doubleTapWindow: 0.4)
        #expect(policy.handle(.pressed(at: 1)) == .ignore)
        #expect(policy.handle(.released(at: 1.05)) == .ignore)
        #expect(policy.handle(.pressed(at: 2)) == .ignore)
        #expect(policy.handle(.released(at: 2.05)) == .ignore)
        #expect(policy.handle(.pressed(at: 2.3)) == .start)
    }

    @Test("session reset makes the next toggle press start again")
    func reset() {
        var policy = HotkeyGesturePolicy(gesture: .toggle)
        #expect(policy.handle(.pressed(at: 1)) == .start)
        policy.reset()
        #expect(policy.handle(.pressed(at: 2)) == .start)
    }
}
