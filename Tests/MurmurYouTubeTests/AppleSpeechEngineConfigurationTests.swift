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
}
