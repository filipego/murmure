import Foundation
import MurmurAudioCore
import MurmurSessionCore

struct RecordingSessionDependencies: Sendable {
    let writeAudio: @Sendable ([AudioChunk], URL) async throws -> Void
    let promoteAudio: @Sendable (URL, UUID) async -> AudioPromotionResult
    let appendHistory: @MainActor @Sendable (DictationRun) async -> Bool
}

enum RecordingSessionCoordinatorError: Error, Sendable {
    case audioStaging(String)
    case invalidCompletionState
}

actor RecordingSessionCoordinator {
    private enum CompletionOutcome {
        case completed(finalText: String)
        case alreadyCompleted
        case failed
    }

    let store: RecordingSessionStore
    private let dependencies: RecordingSessionDependencies

    init(store: RecordingSessionStore, dependencies: RecordingSessionDependencies) {
        self.store = store
        self.dependencies = dependencies
    }

    @discardableResult
    func begin(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        trigger: RecordingTrigger,
        engine: SessionEngineID,
        language: TranscriptionLanguageSelection
    ) async throws -> RecordingSessionManifest {
        let manifest = RecordingSessionManifest(
            id: id,
            startedAt: startedAt,
            trigger: trigger,
            engine: engine,
            language: language
        )
        try await store.create(manifest)
        return manifest
    }

    @discardableResult
    func stageReleasedAudio(
        sessionID: UUID,
        chunks: [AudioChunk],
        releasedAt: Date
    ) async throws -> RecordingSessionManifest {
        let url = await store.stagedAudioURL(for: sessionID)
        do {
            try await dependencies.writeAudio(chunks, url)
            return try await store.release(
                id: sessionID,
                at: releasedAt,
                audioFile: url.lastPathComponent
            )
        } catch {
            let failure = RecordingFailure(stage: .audioStaging, message: error.localizedDescription)
            _ = try? await store.transition(id: sessionID, to: .failed(failure))
            throw RecordingSessionCoordinatorError.audioStaging(error.localizedDescription)
        }
    }

    @discardableResult
    func persistProcessedText(
        sessionID: UUID,
        finalText: String
    ) async throws -> RecordingSessionManifest {
        var manifest = try await store.load(id: sessionID)
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let failure = RecordingFailure(
                stage: .transcription,
                message: "The speech engine returned no text."
            )
            return try await store.transition(id: sessionID, to: .failed(failure))
        }

        switch manifest.status {
        case .readyForTranscription, .failed:
            manifest = try await store.transition(id: sessionID, to: .processing)
        case .processing:
            break
        case .processed(let existing) where existing == finalText:
            return manifest
        default:
            throw RecordingSessionCoordinatorError.invalidCompletionState
        }
        return try await store.transition(id: sessionID, to: .processed(finalText: finalText))
    }

    func completeLiveSession(
        sessionID: UUID,
        run: DictationRun,
        insert: @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        switch await complete(sessionID: sessionID, run: run) {
        case .completed(let finalText):
            await insert(finalText)
            return true
        case .alreadyCompleted:
            return true
        case .failed:
            return false
        }
    }

    @discardableResult
    func fail(sessionID: UUID, failure: RecordingFailure) async -> RecordingSessionManifest? {
        try? await store.transition(id: sessionID, to: .failed(failure))
    }

    @discardableResult
    func cancel(sessionID: UUID) async -> RecordingSessionManifest? {
        try? await store.transition(id: sessionID, to: .cancelled)
    }

    func recoverPendingSessions() async {
        guard let sessions = try? await store.recoverableSessions() else { return }
        for session in sessions {
            guard case let .processed(finalText) = session.status else { continue }
            let releasedAt = session.releasedAt ?? session.startedAt
            let run = DictationRun(
                id: session.id,
                date: releasedAt,
                engine: session.engine.displayName,
                audioSeconds: max(0, releasedAt.timeIntervalSince(session.startedAt)),
                processSeconds: 0,
                text: finalText
            )
            _ = await complete(sessionID: session.id, run: run)
        }
    }

    private func complete(sessionID: UUID, run: DictationRun) async -> CompletionOutcome {
        guard let manifest = try? await store.load(id: sessionID) else { return .failed }
        if manifest.status.isCompleted { return .alreadyCompleted }
        guard case let .processed(finalText) = manifest.status else { return .failed }

        let source = await store.stagedAudioURL(for: sessionID)
        let audioFile: String
        switch await dependencies.promoteAudio(source, sessionID) {
        case .promoted(let relativePath), .alreadyPromoted(let relativePath):
            audioFile = relativePath
        case .failed:
            return .failed
        }

        var durableRun = run
        durableRun.id = sessionID
        durableRun.text = finalText
        durableRun.audioFile = audioFile
        guard await dependencies.appendHistory(durableRun) else { return .failed }
        guard (try? await store.markCompleted(id: sessionID, runID: sessionID)) != nil else {
            return .failed
        }
        return .completed(finalText: finalText)
    }
}

private extension SessionEngineID {
    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .parakeet: "Parakeet"
        }
    }
}

@MainActor
enum RecordingSessionRuntime {
    static let store = RecordingSessionStore(
        rootURL: MurmureDataStore.legacyRootURL
            .appendingPathComponent("Recording Sessions", isDirectory: true)
    )

    static let coordinator = RecordingSessionCoordinator(
        store: store,
        dependencies: RecordingSessionDependencies(
            writeAudio: { chunks, url in
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try AudioArchiveWriter.write(chunks.map(\.buffer), to: url)
                }.value
            },
            promoteAudio: { source, id in
                await AudioHistoryStore.promoteStagedAudio(from: source, id: id)
            },
            appendHistory: { run in
                await RunLog.recordDurably(run)
            }
        )
    )
}
