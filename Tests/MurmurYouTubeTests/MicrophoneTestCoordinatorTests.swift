import AVFoundation
import CoreAudio
import MurmurAudioCore
import Testing
@testable import MurmurYouTube

@Suite("Microphone test coordinator")
@MainActor
struct MicrophoneTestCoordinatorTests {
    @Test("authorized test capture starts and stops without producing content")
    func startsAndStops() async {
        let capture = FakeLevelCapture()
        let input = Self.sampleInput()
        let coordinator = MicrophoneTestCoordinator(
            capture: capture,
            requestPermission: { true },
            resolve: { _ in input }
        )

        await coordinator.start(selection: .systemDefault)

        #expect(coordinator.state == .testing("Studio Mic"))
        #expect(coordinator.resolution == input.resolution)
        #expect(capture.startCount == 1)

        coordinator.stop()

        #expect(coordinator.state == .idle)
        #expect(capture.stopCount == 1)
    }

    @Test("denied microphone permission never opens capture")
    func deniedPermission() async {
        let capture = FakeLevelCapture()
        let coordinator = MicrophoneTestCoordinator(
            capture: capture,
            requestPermission: { false },
            resolve: { _ in Self.sampleInput() }
        )

        await coordinator.start(selection: .systemDefault)

        #expect(coordinator.state == .error("Microphone access is off."))
        #expect(capture.startCount == 0)
    }

    private static func sampleInput() -> LiveAudioInput {
        LiveAudioInput(
            objectID: AudioDeviceID(42),
            resolution: .selected(AudioInputDevice(
                id: "studio",
                displayName: "Studio Mic",
                transport: .usb,
                isSystemDefault: true
            ))
        )
    }
}

@MainActor
private final class FakeLevelCapture: AudioLevelCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(
        deviceID: AudioDeviceID,
        outputFormat: AVAudioFormat,
        onLevel: @escaping @Sendable (Float) -> Void,
        onDeviceChange: @escaping @Sendable () -> Void
    ) throws {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}
