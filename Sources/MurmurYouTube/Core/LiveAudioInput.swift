import CoreAudio
import Foundation
import MurmurAudioCore

struct LiveAudioInput: Sendable {
    let objectID: AudioDeviceID
    let resolution: AudioInputResolution

    var device: AudioInputDevice { resolution.resolvedDevice! }
}

enum LiveAudioInputError: LocalizedError {
    case unavailable(MicrophoneSelection)
    case disappeared(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(selection):
            "No usable microphone is available for \(selection.displayName)."
        case let .disappeared(name):
            "\(name) disconnected before recording could start. Try again to use the current default microphone."
        }
    }
}

enum LiveAudioInputResolver {
    static func resolve(
        _ selection: MicrophoneSelection,
        catalog: CoreAudioInputCatalog = CoreAudioInputCatalog()
    ) throws -> LiveAudioInput {
        let resolution = try catalog.snapshot().resolve(selection)
        guard let device = resolution.resolvedDevice else {
            throw LiveAudioInputError.unavailable(selection)
        }
        guard let objectID = try catalog.objectID(for: device.id) else {
            throw LiveAudioInputError.disappeared(device.displayName)
        }
        return LiveAudioInput(objectID: objectID, resolution: resolution)
    }
}

extension AudioInputResolution {
    var statusText: String {
        switch self {
        case let .selected(device):
            "Using \(device.displayName) · \(device.transport.displayName)"
        case let .fallback(requested, device):
            "\(requested.displayName) is unavailable. Using \(device.displayName) for now; your selection is preserved."
        case let .unavailable(requested):
            "No usable microphone is available for \(requested.displayName)."
        }
    }
}
