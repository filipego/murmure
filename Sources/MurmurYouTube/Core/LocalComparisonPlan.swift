import MurmurSessionCore

enum LocalComparisonParticipant: CaseIterable, Sendable {
    case apple
    case parakeet

    var displayName: String {
        switch self {
        case .apple:
            "Apple"
        case .parakeet:
            "Parakeet"
        }
    }

    func makeEngine(language: TranscriptionLanguageSelection = .systemDefault) -> any TranscriptionEngine {
        switch self {
        case .apple:
            AppleSpeechEngine(language: language)
        case .parakeet:
            ParakeetEngine(language: language)
        }
    }
}
