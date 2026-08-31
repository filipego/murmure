import Foundation
import Observation

enum OnboardingStep: String, CaseIterable, Codable, Sendable {
    case privacy
    case microphonePermission
    case accessibilityPermission
    case shortcut
    case microphoneTest
    case language
    case testDictation
    case complete
}

struct OnboardingReadiness: Equatable, Sendable {
    var microphoneGranted = false
    var accessibilityGranted = false
    var microphoneTested = false
    var testDictationAcknowledged = false
}

enum OnboardingPolicy {
    static func canAdvance(
        from step: OnboardingStep,
        readiness: OnboardingReadiness
    ) -> Bool {
        switch step {
        case .privacy, .shortcut, .language:
            true
        case .microphonePermission:
            readiness.microphoneGranted
        case .accessibilityPermission:
            readiness.accessibilityGranted
        case .microphoneTest:
            readiness.microphoneTested
        case .testDictation:
            readiness.testDictationAcknowledged
        case .complete:
            false
        }
    }
}

@MainActor
@Observable
final class OnboardingState {
    static let shared = OnboardingState()

    private(set) var step: OnboardingStep
    private(set) var isCompleted: Bool

    private let defaults: UserDefaults
    private let stepKey: String
    private let completedKey: String

    init(defaults: UserDefaults = .standard, keyPrefix: String = "onboarding") {
        self.defaults = defaults
        stepKey = "\(keyPrefix).step"
        completedKey = "\(keyPrefix).completed"
        isCompleted = defaults.bool(forKey: completedKey)
        step = OnboardingStep(rawValue: defaults.string(forKey: stepKey) ?? "") ?? .privacy
        if isCompleted { step = .complete }
    }

    func advance(readiness: OnboardingReadiness) {
        guard OnboardingPolicy.canAdvance(from: step, readiness: readiness),
              let index = OnboardingStep.allCases.firstIndex(of: step),
              index + 1 < OnboardingStep.allCases.count else { return }
        step = OnboardingStep.allCases[index + 1]
        persistStep()
    }

    func back() {
        guard let index = OnboardingStep.allCases.firstIndex(of: step), index > 0 else { return }
        step = OnboardingStep.allCases[index - 1]
        persistStep()
    }

    func move(to step: OnboardingStep) {
        self.step = step
        persistStep()
    }

    func complete() {
        step = .complete
        isCompleted = true
        defaults.set(step.rawValue, forKey: stepKey)
        defaults.set(true, forKey: completedKey)
    }

    func reset() {
        step = .privacy
        isCompleted = false
        defaults.removeObject(forKey: stepKey)
        defaults.removeObject(forKey: completedKey)
    }

    private func persistStep() {
        defaults.set(step.rawValue, forKey: stepKey)
    }
}
