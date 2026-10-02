import Testing
@testable import MurmurYouTube

@Suite("Dictation capture startup release policy")
struct DictationCaptureStartupReleasePolicyTests {
    @Test("release before capture readiness cancels startup")
    func releaseBeforeCaptureReadiness() {
        #expect(DictationCaptureStartupReleasePolicy.action(
            captureIsReady: false,
            releaseAlreadyRequested: false
        ) == .cancelStartup)
    }

    @Test("release after capture readiness finishes after engine startup")
    func releaseAfterCaptureReadiness() {
        #expect(DictationCaptureStartupReleasePolicy.action(
            captureIsReady: true,
            releaseAlreadyRequested: false
        ) == .finishAfterStartup)
    }

    @Test("duplicate release during engine startup is ignored")
    func duplicateRelease() {
        #expect(DictationCaptureStartupReleasePolicy.action(
            captureIsReady: true,
            releaseAlreadyRequested: true
        ) == .ignoreDuplicateRelease)
    }
}
