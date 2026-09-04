import Speech
import Testing
@testable import MurmurYouTube

@Suite("Apple speech configuration")
struct AppleSpeechEngineConfigurationTests {
    @Test("streaming requests fast volatile preliminary results")
    func fastVolatileResults() {
        #expect(AppleSpeechConfiguration.reportingOptions.contains(.volatileResults))
        #expect(AppleSpeechConfiguration.reportingOptions.contains(.fastResults))
    }

    @Test("sub-tenth-second captures cancel instead of waiting for finalization")
    func shortCaptureFinalizationPolicy() {
        #expect(AppleSpeechFinalizationPolicy.action(capturedAudioSeconds: 0) == .cancel)
        #expect(AppleSpeechFinalizationPolicy.action(capturedAudioSeconds: 0.062) == .cancel)
        #expect(AppleSpeechFinalizationPolicy.action(capturedAudioSeconds: 0.099) == .cancel)
        #expect(AppleSpeechFinalizationPolicy.action(capturedAudioSeconds: 0.1) == .finalize)
    }
}
