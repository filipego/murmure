import Testing
@testable import MurmurPermissionCore

struct PermissionFlowTests {
    @Test("first microphone action requests access instead of opening an empty settings list")
    func firstActionRequestsAccess() {
        #expect(
            MicrophonePermissionFlow.action(for: .notDetermined) == .requestAccess
        )
    }

    @Test("denied microphone access sends the user to System Settings")
    func deniedActionOpensSettings() {
        #expect(
            MicrophonePermissionFlow.action(for: .denied) == .openSettings
        )
        #expect(
            MicrophonePermissionFlow.action(for: .restricted) == .openSettings
        )
    }

    @Test("authorized microphone access does not ask again")
    func authorizedActionIsComplete() {
        #expect(
            MicrophonePermissionFlow.action(for: .authorized) == .alreadyGranted
        )
    }
}
