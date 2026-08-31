import CoreAudio
import Testing
@testable import MurmurYouTube

@Suite("Audio configuration change policy")
struct AudioConfigurationChangePolicyTests {
    @Test("a benign notification on the running selected device is ignored")
    func benignRunningChange() {
        #expect(AudioConfigurationChangePolicy.action(
            selectedDeviceID: 7,
            currentDeviceID: 7,
            isAlive: true,
            engineIsRunning: true
        ) == .ignore)
    }

    @Test("a benign notification restarts a paused selected device")
    func benignPausedChange() {
        #expect(AudioConfigurationChangePolicy.action(
            selectedDeviceID: 7,
            currentDeviceID: 7,
            isAlive: true,
            engineIsRunning: false
        ) == .restart)
    }

    @Test("a different or dead device fails the active capture")
    func realDeviceLoss() {
        #expect(AudioConfigurationChangePolicy.action(
            selectedDeviceID: 7,
            currentDeviceID: 8,
            isAlive: true,
            engineIsRunning: true
        ) == .fail)
        #expect(AudioConfigurationChangePolicy.action(
            selectedDeviceID: 7,
            currentDeviceID: 7,
            isAlive: false,
            engineIsRunning: true
        ) == .fail)
    }
}
