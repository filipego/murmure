/// The action a Settings permission row should take for the current microphone state.
///
/// Keeping this decision separate from AVFoundation makes the behavior deterministic and
/// testable: the first click must ask the app for access, while a previously denied grant
/// belongs in System Settings.
public enum MicrophoneAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public enum MicrophonePermissionAction: Equatable, Sendable {
    case requestAccess
    case openSettings
    case alreadyGranted
}

public enum MicrophonePermissionFlow {
    public static func action(
        for authorization: MicrophoneAuthorization
    ) -> MicrophonePermissionAction {
        switch authorization {
        case .notDetermined:
            .requestAccess
        case .authorized:
            .alreadyGranted
        case .denied, .restricted:
            .openSettings
        }
    }
}
