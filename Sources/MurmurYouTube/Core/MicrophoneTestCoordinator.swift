import AVFoundation
import CoreAudio
import Foundation
import MurmurAudioCore
import Observation

@MainActor
protocol AudioLevelCapturing: AnyObject {
    func start(
        deviceID: AudioDeviceID,
        outputFormat: AVAudioFormat,
        onLevel: @escaping @Sendable (Float) -> Void,
        onDeviceChange: @escaping @Sendable () -> Void
    ) throws
    func stop()
}

extension AudioCapture: AudioLevelCapturing {
    func start(
        deviceID: AudioDeviceID,
        outputFormat: AVAudioFormat,
        onLevel: @escaping @Sendable (Float) -> Void,
        onDeviceChange: @escaping @Sendable () -> Void
    ) throws {
        try start(
            deviceID: deviceID,
            outputFormat: outputFormat,
            onBuffer: { _ in },
            onLevel: onLevel,
            onDeviceChange: onDeviceChange
        )
    }
}

@MainActor
@Observable
final class MicrophoneTestCoordinator {
    enum State: Equatable {
        case idle
        case starting
        case testing(String)
        case error(String)

        var isBusy: Bool {
            switch self {
            case .starting, .testing: true
            case .idle, .error: false
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var level: Float = 0
    private(set) var resolution: AudioInputResolution?

    private let capture: any AudioLevelCapturing
    private let requestPermission: @MainActor @Sendable () async -> Bool
    private let resolve: @MainActor @Sendable (MicrophoneSelection) throws -> LiveAudioInput
    private var attemptID: UUID?

    convenience init() {
        self.init(
            capture: AudioCapture(),
            requestPermission: { await Permissions.requestMicrophone() },
            resolve: { try LiveAudioInputResolver.resolve($0) }
        )
    }

    init(
        capture: any AudioLevelCapturing,
        requestPermission: @escaping @MainActor @Sendable () async -> Bool,
        resolve: @escaping @MainActor @Sendable (MicrophoneSelection) throws -> LiveAudioInput
    ) {
        self.capture = capture
        self.requestPermission = requestPermission
        self.resolve = resolve
    }

    func start(selection: MicrophoneSelection) async {
        guard !state.isBusy else { return }
        let id = UUID()
        attemptID = id
        state = .starting
        level = 0
        resolution = nil

        guard await requestPermission() else {
            guard attemptID == id else { return }
            attemptID = nil
            state = .error("Microphone access is off.")
            return
        }
        guard attemptID == id else { return }

        do {
            let input = try resolve(selection)
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ) else {
                throw TranscriptionError.noAudioFormat
            }
            try capture.start(
                deviceID: input.objectID,
                outputFormat: format,
                onLevel: { [weak self] level in
                    Task { @MainActor in
                        guard self?.attemptID == id else { return }
                        self?.level = level
                    }
                },
                onDeviceChange: { [weak self] in
                    Task { @MainActor in
                        guard self?.attemptID == id else { return }
                        self?.fail("The microphone changed or disconnected.")
                    }
                }
            )
            guard attemptID == id else {
                capture.stop()
                return
            }
            resolution = input.resolution
            state = .testing(input.device.displayName)
        } catch {
            guard attemptID == id else { return }
            fail(error.localizedDescription)
        }
    }

    func stop() {
        attemptID = nil
        capture.stop()
        level = 0
        resolution = nil
        state = .idle
    }

    private func fail(_ message: String) {
        attemptID = nil
        capture.stop()
        level = 0
        resolution = nil
        state = .error(message)
    }
}
