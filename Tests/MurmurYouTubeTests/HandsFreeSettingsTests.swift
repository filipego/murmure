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
