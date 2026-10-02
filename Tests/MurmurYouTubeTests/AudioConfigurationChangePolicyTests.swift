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

    @Test("a selected device remains active when it is a current aggregate subdevice")
    func activeAggregateSubdevice() {
        #expect(AudioConfigurationChangePolicy.action(
            selectedDeviceID: 125,
            currentDeviceID: 162,
            activeSubDeviceIDs: [125, 119],
            isAlive: true,
            engineIsRunning: true
        ) == .ignore)
        #expect(AudioConfigurationChangePolicy.action(
            selectedDeviceID: 125,
            currentDeviceID: 162,
            activeSubDeviceIDs: [125, 119],
            isAlive: true,
            engineIsRunning: false
        ) == .restart)
    }

    @Test("an unverified aggregate membership fails closed")
    func aggregateWithoutSelectedSubdeviceFails() {
        #expect(AudioConfigurationChangePolicy.action(
            selectedDeviceID: 125,
            currentDeviceID: 162,
            activeSubDeviceIDs: [119],
            isAlive: true,
            engineIsRunning: true
        ) == .fail)
        #expect(AudioConfigurationChangePolicy.action(
            selectedDeviceID: 125,
            currentDeviceID: 162,
            activeSubDeviceIDs: [],
            isAlive: true,
            engineIsRunning: true
        ) == .fail)
    }

    @Test("dead and unknown selected devices fail even with aggregate membership")
    func deadOrUnknownAggregateSubdeviceFails() {
        #expect(AudioConfigurationChangePolicy.action(
            selectedDeviceID: 125,
            currentDeviceID: 162,
            activeSubDeviceIDs: [125, 119],
            isAlive: false,
            engineIsRunning: true
        ) == .fail)
        #expect(AudioConfigurationChangePolicy.action(
            selectedDeviceID: AudioDeviceID(kAudioObjectUnknown),
            currentDeviceID: 162,
            activeSubDeviceIDs: [AudioDeviceID(kAudioObjectUnknown)],
            isAlive: true,
            engineIsRunning: true
        ) == .fail)
        #expect(AudioConfigurationChangePolicy.action(
            selectedDeviceID: AudioDeviceID(kAudioObjectUnknown),
            currentDeviceID: AudioDeviceID(kAudioObjectUnknown),
            isAlive: true,
            engineIsRunning: true
        ) == .fail)
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
