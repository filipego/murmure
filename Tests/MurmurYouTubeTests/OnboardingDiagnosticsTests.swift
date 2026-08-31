import Foundation
import Testing
@testable import MurmurYouTube

@Suite("Onboarding policy")
struct OnboardingPolicyTests {
    @Test("permission and proof steps gate forward progress")
    func readinessGates() {
        let empty = OnboardingReadiness()
        #expect(OnboardingStep.allCases.first == .appLanguage)
        #expect(OnboardingPolicy.canAdvance(from: .appLanguage, readiness: empty))
        #expect(OnboardingPolicy.canAdvance(from: .privacy, readiness: empty))
        #expect(!OnboardingPolicy.canAdvance(from: .microphonePermission, readiness: empty))
        #expect(!OnboardingPolicy.canAdvance(from: .accessibilityPermission, readiness: empty))
        #expect(!OnboardingPolicy.canAdvance(from: .microphoneTest, readiness: empty))
        #expect(!OnboardingPolicy.canAdvance(from: .testDictation, readiness: empty))

        let ready = OnboardingReadiness(
            microphoneGranted: true,
            accessibilityGranted: true,
            microphoneTested: true,
            testDictationAcknowledged: true
        )
        #expect(OnboardingStep.allCases.dropLast().allSatisfy {
            OnboardingPolicy.canAdvance(from: $0, readiness: ready)
        })
    }

    @Test("completion and reset are idempotent and preserve no unrelated defaults")
    @MainActor
    func persistenceAndReset() {
        let suite = "OnboardingDiagnosticsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("keep", forKey: "unrelated")
        let state = OnboardingState(defaults: defaults, keyPrefix: "test")

        state.complete()
        state.complete()
        #expect(state.isCompleted)
        #expect(OnboardingState(defaults: defaults, keyPrefix: "test").isCompleted)

        state.reset()
        state.reset()
        #expect(!state.isCompleted)
        #expect(state.step == .appLanguage)
        #expect(defaults.string(forKey: "unrelated") == "keep")
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("back and forward transitions stay inside the declared sequence")
    @MainActor
    func transitions() {
        let suite = "OnboardingTransitions-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let state = OnboardingState(defaults: defaults, keyPrefix: "test")
        let ready = OnboardingReadiness(
            microphoneGranted: true,
            accessibilityGranted: true,
            microphoneTested: true,
            testDictationAcknowledged: true
        )

        state.back()
        #expect(state.step == .appLanguage)
        state.advance(readiness: ready)
        #expect(state.step == .privacy)
        state.back()
        #expect(state.step == .appLanguage)
        defaults.removePersistentDomain(forName: suite)
    }
}

@Suite("Sanitized diagnostics")
struct DiagnosticsCollectorTests {
    @Test("snapshot exposes setup facts and omits private content")
    func redaction() throws {
        let canary = "PRIVATE TRANSCRIPT CANARY"
        let snapshot = DiagnosticsCollector.collect(from: DiagnosticsInput(
            appVersion: "1.2.3",
            appBuild: "45",
            macOSVersion: "26.0",
            architecture: "arm64",
            microphone: "Studio Mic",
            engine: "Parakeet",
            language: "Automatic",
            modelState: "Installed",
            microphonePermission: "Granted",
            accessibilityPermission: "Granted",
            storageState: "External storage ready",
            recentOperationFailed: true,
            privateContentProbe: canary
        ))
        let data = try DiagnosticsCollector.encoded(snapshot)
        let text = String(decoding: data, as: UTF8.self)

        #expect(snapshot.appVersion == "1.2.3 (45)")
        #expect(snapshot.lastFailure == "A recent local operation failed; see Murmure for its current message.")
        #expect(!text.contains(canary))
        #expect(!text.localizedCaseInsensitiveContains("transcript"))
        #expect(!text.contains("/Volumes/"))
        #expect(try JSONDecoder().decode(DiagnosticsSnapshot.self, from: data) == snapshot)
    }
}
