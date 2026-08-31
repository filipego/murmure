import Foundation
import Testing
@testable import MurmurAudioCore

@Suite("Audio input resolver")
struct AudioInputResolverTests {
    private let builtIn = AudioInputDevice(
        id: "builtin",
        displayName: "MacBook Microphone",
        transport: .builtIn,
        isSystemDefault: true
    )
    private let usb = AudioInputDevice(
        id: "usb-123",
        displayName: "Studio Mic",
        transport: .usb,
        isSystemDefault: false
    )

    @Test("system default resolves to the current default device")
    func systemDefault() {
        let result = AudioInputResolver.resolve(
            .systemDefault,
            devices: [usb, builtIn],
            defaultDeviceID: builtIn.id
        )

        #expect(result == .selected(builtIn))
    }

    @Test("an available explicit device resolves without changing its display name")
    func explicitDevice() {
        let result = AudioInputResolver.resolve(
            .device(uniqueID: usb.id, displayName: "Old label"),
            devices: [builtIn, usb],
            defaultDeviceID: builtIn.id
        )

        #expect(result == .selected(usb))
    }

    @Test("a missing explicit device falls back but preserves the requested selection")
    func missingDeviceFallback() {
        let requested = MicrophoneSelection.device(
            uniqueID: "missing",
            displayName: "Disconnected Mic"
        )
        let result = AudioInputResolver.resolve(
            requested,
            devices: [builtIn],
            defaultDeviceID: builtIn.id
        )

        #expect(result == .fallback(requested: requested, device: builtIn))
        #expect(result.resolvedDevice == builtIn)
    }

    @Test("reconnection restores the explicit device automatically")
    func reconnect() {
        let requested = MicrophoneSelection.device(
            uniqueID: usb.id,
            displayName: usb.displayName
        )

        let missing = AudioInputResolver.resolve(
            requested,
            devices: [builtIn],
            defaultDeviceID: builtIn.id
        )
        let reconnected = AudioInputResolver.resolve(
            requested,
            devices: [builtIn, usb],
            defaultDeviceID: builtIn.id
        )

        #expect(missing == .fallback(requested: requested, device: builtIn))
        #expect(reconnected == .selected(usb))
    }

    @Test("no default input reports an unavailable selection")
    func noInput() {
        #expect(AudioInputResolver.resolve(
            .systemDefault,
            devices: [],
            defaultDeviceID: nil
        ) == .unavailable(requested: .systemDefault))
    }

    @Test("selection survives a JSON round trip")
    func codableSelection() throws {
        let selection = MicrophoneSelection.device(
            uniqueID: usb.id,
            displayName: usb.displayName
        )

        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(MicrophoneSelection.self, from: data)

        #expect(decoded == selection)
    }
}
