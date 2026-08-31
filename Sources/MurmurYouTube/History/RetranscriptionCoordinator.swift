import Foundation
import MurmurDictionary
import MurmurSessionCore

enum RetranscriptionSource: Equatable, Sendable, Identifiable {
    case history(DictationRun)
    case recoverable(RecoverableRecording)

    var id: UUID {
        switch self {
        case .history(let run): run.id
        case .recoverable(let recording): recording.id
        }
    }

    var audioURL: URL? {
        switch self {
        case .history(let run):
            run.audioFile.flatMap(AudioHistoryStore.url(for:))
        case .recoverable(let recording):
            recording.audioURL
        }
    }
}

struct RetranscriptionPreview: Equatable, Sendable, Identifiable {
    let id: UUID
    let source: RetranscriptionSource
    let engine: SpeechEngineChoice
    let rawText: String
    let candidateText: String
    let processSeconds: Double
    let corrections: [AppliedCorrection]
    fileprivate let candidateRun: DictationRun
}

enum RetranscriptionError: LocalizedError, Equatable, Sendable {
    case audioUnavailable
    case blankCandidate

    var errorDescription: String? {
        switch self {
        case .audioUnavailable:
            "The saved recording is no longer available."
        case .blankCandidate:
            "No usable words remained after local cleanup."
        }
    }
}

struct RetranscriptionDependencies: Sendable {
    let transcribe: @Sendable (URL, SpeechEngineChoice) async throws -> ArchivedTranscription
    let format: @Sendable (String) async -> String
    let correct: @Sendable (String) async -> (String, [AppliedCorrection])
    let replaceHistory: @Sendable (DictationRun, DictationRun) async -> Bool
    let persistProcessed: @Sendable (UUID, String) async throws -> Void
    let completeRecovered: @Sendable (UUID, DictationRun) async -> Bool
    let refreshRecoverables: @Sendable () async -> Void
    let now: @Sendable () -> Date

    static func live() -> RetranscriptionDependencies {
        RetranscriptionDependencies(
            transcribe: { url, choice in
                let engine: any TranscriptionEngine = switch choice {
                case .apple: AppleSpeechEngine()
                case .parakeet: ParakeetEngine()
                }
                return try await ArchivedAudioTranscriber.transcribe(url: url, engine: engine)
            },
            format: { raw in
                let formatter: any TextFormatter = await MainActor.run {
                    guard Settings.shared.cleanupEnabled else { return PassthroughFormatter() }
                    return Settings.shared.smartCleanup
                        ? FoundationModelFormatter()
                        : RuleBasedFormatter()
                }
                return await formatter.format(raw)
            },
            correct: { text in
                let corrector = await MainActor.run { DictionaryStore.shared.corrector }
                let result = corrector.apply(to: text)
                return (result.text, result.applied)
            },
            replaceHistory: { expected, replacement in
                await RunLog.replaceDurably(expected: expected, with: replacement)
            },
            persistProcessed: { id, text in
                _ = try await RecordingSessionRuntime.coordinator.persistProcessedText(
                    sessionID: id,
                    finalText: text
                )
            },
            completeRecovered: { id, run in
                await RecordingSessionRuntime.coordinator.completeRecoveredSession(
                    sessionID: id,
                    run: run
                )
            },
            refreshRecoverables: {
                await RecoverableRecordingStore.shared.refresh()
            },
            now: Date.init
        )
    }
}

@MainActor
final class RetranscriptionCoordinator {
    private let dependencies: RetranscriptionDependencies
    private var activePreview: RetranscriptionPreview?

    init(dependencies: RetranscriptionDependencies? = nil) {
        self.dependencies = dependencies ?? .live()
    }

    func preview(
        source: RetranscriptionSource,
        engine: SpeechEngineChoice
    ) async throws -> RetranscriptionPreview {
        guard let audioURL = source.audioURL else {
            throw RetranscriptionError.audioUnavailable
        }
        let transcription = try await dependencies.transcribe(audioURL, engine)
        let formatted = await dependencies.format(transcription.text)
        let (candidateText, corrections) = await dependencies.correct(formatted)
        guard !candidateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RetranscriptionError.blankCandidate
        }

        let candidateRun = makeCandidateRun(
            source: source,
            engine: engine,
            text: candidateText,
            processSeconds: transcription.processSeconds,
            corrections: corrections
        )
        let preview = RetranscriptionPreview(
            id: UUID(),
            source: source,
            engine: engine,
            rawText: transcription.text,
            candidateText: candidateText,
            processSeconds: transcription.processSeconds,
            corrections: corrections,
            candidateRun: candidateRun
        )
        activePreview = preview
        return preview
    }

    func confirm(_ preview: RetranscriptionPreview) async -> Bool {
        guard activePreview == preview else { return false }

        let saved: Bool
        switch preview.source {
        case .history(let expected):
            saved = await dependencies.replaceHistory(expected, preview.candidateRun)
        case .recoverable(let recording):
            do {
                try await dependencies.persistProcessed(recording.id, preview.candidateText)
            } catch {
                return false
            }
            saved = await dependencies.completeRecovered(recording.id, preview.candidateRun)
            if saved { await dependencies.refreshRecoverables() }
        }

        if saved { activePreview = nil }
        return saved
    }

    func cancel() {
        activePreview = nil
    }

    private func makeCandidateRun(
        source: RetranscriptionSource,
        engine: SpeechEngineChoice,
        text: String,
        processSeconds: Double,
        corrections: [AppliedCorrection]
    ) -> DictationRun {
        switch source {
        case .history(let original):
            let previous = original.correction
            let correction = TranscriptCorrectionRecord(
                heardText: previous?.heardText ?? original.text,
                intendedText: text,
                correctedAt: dependencies.now(),
                inputMethod: .retranscription,
                rememberedRule: previous?.rememberedRule,
                pendingRule: previous?.pendingRule
            )
            return DictationRun(
                id: original.id,
                date: original.date,
                engine: engine.historyName,
                audioSeconds: original.audioSeconds,
                processSeconds: processSeconds,
                text: text,
                group: original.group,
                corrections: corrections.isEmpty ? nil : corrections,
                audioFile: original.audioFile,
                correction: correction
            )
        case .recoverable(let recording):
            let releasedAt = recording.releasedAt ?? recording.startedAt
            return DictationRun(
                id: recording.id,
                date: releasedAt,
                engine: engine.historyName,
                audioSeconds: max(0, releasedAt.timeIntervalSince(recording.startedAt)),
                processSeconds: processSeconds,
                text: text,
                corrections: corrections.isEmpty ? nil : corrections
            )
        }
    }
}

private extension SpeechEngineChoice {
    var historyName: String {
        switch self {
        case .apple: "Apple"
        case .parakeet: "Parakeet"
        }
    }
}
