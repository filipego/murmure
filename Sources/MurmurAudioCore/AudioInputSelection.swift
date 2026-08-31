import Foundation

public enum MicrophoneSelection: Codable, Sendable, Equatable, Hashable {
    case systemDefault
    case device(uniqueID: String, displayName: String)

    public var displayName: String {
        switch self {
        case .systemDefault:
            "System default"
        case let .device(_, displayName):
            displayName
        }
    }
}

public enum AudioInputTransport: String, Codable, Sendable, Equatable, Hashable {
    case builtIn
    case usb
    case bluetooth
    case thunderbolt
    case aggregate
    case virtual
    case continuity
    case other

    public var displayName: String {
        switch self {
        case .builtIn: "Built-in"
        case .usb: "USB"
        case .bluetooth: "Bluetooth"
        case .thunderbolt: "Thunderbolt"
        case .aggregate: "Aggregate"
        case .virtual: "Virtual"
        case .continuity: "Continuity"
        case .other: "Other"
        }
    }
}

public struct AudioInputDevice: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let transport: AudioInputTransport
    public let isSystemDefault: Bool

    public init(
        id: String,
        displayName: String,
        transport: AudioInputTransport,
        isSystemDefault: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.isSystemDefault = isSystemDefault
    }
}

public enum AudioInputResolution: Sendable, Equatable {
    case selected(AudioInputDevice)
    case fallback(requested: MicrophoneSelection, device: AudioInputDevice)
    case unavailable(requested: MicrophoneSelection)

    public var resolvedDevice: AudioInputDevice? {
        switch self {
        case let .selected(device), let .fallback(_, device):
            device
        case .unavailable:
            nil
        }
    }
}

public enum AudioInputResolver {
    public static func resolve(
        _ selection: MicrophoneSelection,
        devices: [AudioInputDevice],
        defaultDeviceID: String?
    ) -> AudioInputResolution {
        let defaultDevice = devices.first { device in
            if let defaultDeviceID { return device.id == defaultDeviceID }
            return device.isSystemDefault
        }

        switch selection {
        case .systemDefault:
            guard let defaultDevice else {
                return .unavailable(requested: selection)
            }
            return .selected(defaultDevice)

        case let .device(uniqueID, _):
            if let selected = devices.first(where: { $0.id == uniqueID }) {
                return .selected(selected)
            }
            guard let defaultDevice else {
                return .unavailable(requested: selection)
            }
            return .fallback(requested: selection, device: defaultDevice)
        }
    }
}
