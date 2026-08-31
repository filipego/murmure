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

    func makeEngine() -> any TranscriptionEngine {
        switch self {
        case .apple:
            AppleSpeechEngine()
        case .parakeet:
            ParakeetEngine()
        }
    }
}
