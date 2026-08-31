import Foundation
import Testing
@testable import MurmurYouTube

@Suite("Hands-free settings")
struct HandsFreeSettingsTests {
    @Test("legacy settings decode with hands-free disabled")
    func legacySnapshot() throws {
        let data = Data(#"{"pushToTalkKey":"fn","engine":"apple","compareMode":false,"cleanupEnabled":true,"smartCleanup":false,"soundEnabled":true}"#.utf8)

        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)

        #expect(snapshot.resolvedHandsFreeEnabled == false)
        #expect(snapshot.resolvedHandsFreeKey == .rightCommand)
        #expect(snapshot.resolvedMicrophoneSelection == .systemDefault)
        #expect(snapshot.resolvedPushToTalkBinding == PushToTalkKey.fn.binding(gesture: .hold))
        #expect(snapshot.resolvedHandsFreeBinding == PushToTalkKey.rightCommand.binding(gesture: .toggle))
    }

    @Test("an explicit microphone survives settings decoding")
    func microphoneSnapshot() throws {
        let data = Data(#"{"pushToTalkKey":"fn","engine":"apple","compareMode":false,"cleanupEnabled":true,"smartCleanup":false,"soundEnabled":true,"microphoneSelection":{"device":{"uniqueID":"usb-123","displayName":"Studio Mic"}}}"#.utf8)

        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)

        #expect(snapshot.resolvedMicrophoneSelection == .device(
            uniqueID: "usb-123",
            displayName: "Studio Mic"
        ))
    }

    @Test("a duplicate persisted binding is normalized")
    func duplicateBinding() {
        let selection = HotkeyBindingSelection(
            pushToTalk: .rightCommand,
            handsFree: .rightCommand
        )

        #expect(selection.pushToTalk == .rightCommand)
        #expect(selection.handsFree == .rightOption)
    }

    @Test("typed bindings survive the complete settings snapshot")
    func typedSnapshot() throws {
        let data = Data(#"{"pushToTalkKey":"fn","engine":"parakeet","compareMode":false,"cleanupEnabled":true,"smartCleanup":false,"soundEnabled":true,"pushToTalkBinding":{"keyCode":49,"requiredFlags":1179648,"gesture":"doubleTapHold","consumption":"suppress","label":"⇧⌘Space"},"handsFreeBinding":{"keyCode":54,"requiredFlags":16,"side":"right","gesture":"toggle","consumption":"suppress","label":"Right ⌘"}}"#.utf8)

        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)

        #expect(snapshot.resolvedPushToTalkBinding.label == "⇧⌘Space")
        #expect(snapshot.resolvedPushToTalkBinding.gesture == .doubleTapHold)
        #expect(snapshot.resolvedHandsFreeBinding == PushToTalkKey.rightCommand.binding(gesture: .toggle))
    }

    @Test("duplicate typed bindings are repaired before use")
    func duplicateTypedBinding() {
        let duplicate = PushToTalkKey.rightCommand.binding(gesture: .hold)
        let registry = HotkeyBindingRegistry(
            pushToTalk: duplicate,
            handsFree: duplicate.withGesture(.toggle)
        )

        #expect(registry.pushToTalk.id != registry.handsFree.id)
        #expect(registry.handsFree == PushToTalkKey.fn.binding(gesture: .toggle))
    }

    @Test("changing push-to-talk moves a colliding hands-free binding")
    func changingPushToTalk() {
        let selection = HotkeyBindingSelection(
            pushToTalk: .fn,
            handsFree: .rightCommand
        ).selectingPushToTalk(.rightCommand)

        #expect(selection.pushToTalk == .rightCommand)
        #expect(selection.handsFree == .rightOption)
    }

    @Test("the hands-free picker cannot select push-to-talk")
    func changingHandsFree() {
        let original = HotkeyBindingSelection(
            pushToTalk: .fn,
            handsFree: .rightCommand
        )

        #expect(original.selectingHandsFree(.fn) == original)
        #expect(original.selectingHandsFree(.rightOption).handsFree == .rightOption)
    }
}
