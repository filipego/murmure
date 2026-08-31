import Foundation
import MurmurSessionCore
import Testing
@testable import MurmurYouTube

@Suite("Recording session coordinator")
struct RecordingSessionCoordinatorTests {
    @Test("released audio is staged before the manifest becomes ready")
    func audioPrecedesReadyStatus() async throws {
        try await withCoordinatorFixture { fixture in
            let session = try await fixture.coordinator.begin(
                id: fixture.sessionID,
                startedAt: fixture.startedAt,
                trigger: .mainButton,
                engine: .apple,
                language: .systemDefault
            )

            let released = try await fixture.coordinator.stageReleasedAudio(
                sessionID: session.id,
                chunks: [],
                releasedAt: fixture.releasedAt
            )

            #expect(await fixture.events.values.first == "write:recording")
            #expect(released.status == .readyForTranscription)
            #expect(FileManager.default.fileExists(atPath: await fixture.store.stagedAudioURL(for: session.id).path))
        }
    }

    @Test("final text is durable before completion permits one live insertion")
    func textPrecedesLiveInsertion() async throws {
        try await withCoordinatorFixture { fixture in
            try await fixture.prepareProcessedSession(text: "Bonjour tout le monde.")
            let run = fixture.run(text: "Bonjour tout le monde.")

            let completed = await fixture.coordinator.completeLiveSession(
                sessionID: fixture.sessionID,
                run: run,
                insert: { text in fixture.insertions.append(text) }
            )

            #expect(completed)
            #expect(await fixture.events.values == [
                "write:recording",
                "promote:processed",
                "append:processed"
            ])
            #expect(fixture.insertions == ["Bonjour tout le monde."])
            #expect(try await fixture.store.load(id: fixture.sessionID).status.isCompleted)
        }
    }

    @Test("promotion failure leaves processed text recoverable")
    func promotionFailureRemainsRecoverable() async throws {
        try await withCoordinatorFixture(promoteSucceeds: false) { fixture in
            try await fixture.prepareProcessedSession(text: "Recover me")

            #expect(!(await fixture.coordinator.completeLiveSession(
                sessionID: fixture.sessionID,
                run: fixture.run(text: "Recover me"),
                insert: { _ in fixture.insertions.append("unexpected") }
            )))
            #expect(
                try await fixture.store.load(id: fixture.sessionID).status
                    == .processed(finalText: "Recover me")
            )
            #expect(fixture.insertions.isEmpty)
        }
    }

    @Test("repeating completion does not duplicate history or insertion")
    func repeatedCompletionIsIdempotent() async throws {
        try await withCoordinatorFixture { fixture in
            try await fixture.prepareProcessedSession(text: "Only once")
            let run = fixture.run(text: "Only once")

            #expect(await fixture.coordinator.completeLiveSession(
                sessionID: fixture.sessionID,
                run: run,
                insert: { text in fixture.insertions.append(text) }
            ))
            #expect(await fixture.coordinator.completeLiveSession(
                sessionID: fixture.sessionID,
                run: run,
                insert: { text in fixture.insertions.append(text) }
            ))

            #expect(await fixture.history.count == 1)
            #expect(fixture.insertions == ["Only once"])
        }
    }

    @Test("launch recovery completes processed sessions without insertion")
    func recoveryCompletesWithoutInsertion() async throws {
        try await withCoordinatorFixture { fixture in
            try await fixture.prepareProcessedSession(text: "Recovered locally")

            await fixture.coordinator.recoverPendingSessions()

            #expect(await fixture.history.count == 1)
            #expect(fixture.insertions.isEmpty)
            #expect(try await fixture.store.load(id: fixture.sessionID).status.isCompleted)
        }
    }

    @Test("empty recognition retains staged audio as a transcription failure")
    func emptyRecognitionIsRecoverable() async throws {
        try await withCoordinatorFixture { fixture in
            let session = try await fixture.coordinator.begin(
                id: fixture.sessionID,
                startedAt: fixture.startedAt,
                trigger: .mainButton,
                engine: .apple,
                language: .systemDefault
            )
            _ = try await fixture.coordinator.stageReleasedAudio(
                sessionID: session.id,
                chunks: [],
                releasedAt: fixture.releasedAt
            )

            let failed = try await fixture.coordinator.persistProcessedText(
                sessionID: session.id,
                finalText: "   "
            )

            guard case let .failed(failure) = failed.status else {
                Issue.record("Expected a durable transcription failure")
                return
            }
            #expect(failure.stage == .transcription)
            #expect(FileManager.default.fileExists(atPath: await fixture.store.stagedAudioURL(for: session.id).path))
        }
    }

    @Test("recoverable recordings require released nonempty audio and are newest first")
    func recoverableRecordingCatalog() async throws {
        try await withCoordinatorFixture { fixture in
            let olderID = UUID(uuidString: "00000000-0000-0000-0000-000000000061")!
            let newerID = UUID(uuidString: "00000000-0000-0000-0000-000000000062")!
            let emptyID = UUID(uuidString: "00000000-0000-0000-0000-000000000063")!
            let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000064")!
            let completedID = UUID(uuidString: "00000000-0000-0000-0000-000000000065")!
            let failure = RecordingFailure(stage: .transcription, message: "No words recognized")

            try await fixture.store.create(RecordingSessionManifest(
                id: olderID,
                startedAt: Date(timeIntervalSince1970: 20),
                trigger: .mainButton,
                engine: .apple,
                language: .systemDefault,
                releasedAt: Date(timeIntervalSince1970: 22),
                audioFile: "audio.caf",
                status: .failed(failure)
            ))
            try await fixture.store.create(RecordingSessionManifest(
                id: newerID,
                startedAt: Date(timeIntervalSince1970: 30),
                trigger: .mainButton,
                engine: .parakeet,
                language: .systemDefault,
                releasedAt: Date(timeIntervalSince1970: 34),
                audioFile: "audio.caf",
                status: .readyForTranscription
            ))
            try await fixture.store.create(RecordingSessionManifest(
                id: emptyID,
                startedAt: Date(timeIntervalSince1970: 40),
                trigger: .mainButton,
                engine: .apple,
                language: .systemDefault,
                releasedAt: Date(timeIntervalSince1970: 41),
                audioFile: "audio.caf",
                status: .readyForTranscription
            ))
            try await fixture.store.create(RecordingSessionManifest(
                id: recordingID,
                startedAt: Date(timeIntervalSince1970: 50),
                trigger: .mainButton,
                engine: .apple,
                language: .systemDefault
            ))
            try await fixture.store.create(RecordingSessionManifest(
                id: completedID,
                startedAt: Date(timeIntervalSince1970: 60),
                trigger: .mainButton,
                engine: .apple,
                language: .systemDefault,
                releasedAt: Date(timeIntervalSince1970: 61),
                audioFile: "audio.caf",
                status: .completed(runID: completedID)
            ))

            try Data("older audio".utf8).write(to: await fixture.store.stagedAudioURL(for: olderID))
            try Data("newer audio".utf8).write(to: await fixture.store.stagedAudioURL(for: newerID))
            try Data().write(to: await fixture.store.stagedAudioURL(for: emptyID))
            try Data("completed audio".utf8).write(to: await fixture.store.stagedAudioURL(for: completedID))

            let recordings = await fixture.coordinator.recoverableRecordings()

            #expect(recordings.map(\.id) == [newerID, olderID])
            #expect(recordings[0].engine == .parakeet)
            #expect(recordings[0].status == .readyForTranscription)
            #expect(recordings[1].failure == failure)
            #expect(recordings.allSatisfy { $0.audioURL.lastPathComponent == "audio.caf" })
        }
    }

    @Test("confirmed recovery completes without an insertion capability or duplicate history")
    func confirmedRecoveryIsNonInsertingAndIdempotent() async throws {
        try await withCoordinatorFixture { fixture in
            try await fixture.prepareProcessedSession(text: "Recovered from history")
            let run = fixture.run(text: "Recovered from history")

            #expect(await fixture.coordinator.completeRecoveredSession(
                sessionID: fixture.sessionID,
                run: run
            ))
            #expect(await fixture.coordinator.completeRecoveredSession(
                sessionID: fixture.sessionID,
                run: run
            ))

            #expect(await fixture.history.count == 1)
            #expect(fixture.insertions.isEmpty)
            #expect(try await fixture.store.load(id: fixture.sessionID).status.isCompleted)
        }
    }

    @Test("recoverable store publishes an immutable coordinator snapshot")
    @MainActor
    func recoverableStoreRefreshes() async {
        let failure = RecordingFailure(stage: .transcription, message: "Try again")
        let expected = RecoverableRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000070")!,
            startedAt: Date(timeIntervalSince1970: 10),
            releasedAt: Date(timeIntervalSince1970: 12),
            trigger: .mainButton,
            engine: .apple,
            language: .systemDefault,
            status: .failed(failure),
            audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
            failure: failure
        )
        let store = RecoverableRecordingStore(load: { [expected] })

        await store.refresh()

        #expect(store.recordings == [expected])
    }
}

@MainActor
private final class CoordinatorFixture {
    let store: RecordingSessionStore
    let coordinator: RecordingSessionCoordinator
    let events: EventRecorder
    let history: HistoryRecorder
    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!
    let startedAt = Date(timeIntervalSince1970: 10)
    let releasedAt = Date(timeIntervalSince1970: 13)
    var insertions: [String] = []

    init(root: URL, promoteSucceeds: Bool) {
        let store = RecordingSessionStore(rootURL: root)
        let events = EventRecorder()
        let history = HistoryRecorder()
        let expectedSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!
        self.store = store
        self.events = events
        self.history = history
        coordinator = RecordingSessionCoordinator(
            store: store,
            dependencies: RecordingSessionDependencies(
                writeAudio: { _, url in
                    let status = try await store.load(id: expectedSessionID).status
                    await events.append("write:\(status.phaseName)")
                    try Data("staged audio".utf8).write(to: url)
                },
                promoteAudio: { url, id in
                    let status = try? await store.load(id: id).status
                    await events.append("promote:\(status?.phaseName ?? "missing")")
                    return promoteSucceeds
                        ? .promoted(relativePath: "Recordings/\(id.uuidString.lowercased()).caf")
                        : .failed("Destination unavailable")
                },
                appendHistory: { run in
                    let status = try? await store.load(id: run.id).status
                    await events.append("append:\(status?.phaseName ?? "missing")")
                    return await history.appendIfAbsent(run)
                }
            )
        )
    }

    func prepareProcessedSession(text: String) async throws {
        let session = try await coordinator.begin(
            id: sessionID,
            startedAt: startedAt,
            trigger: .mainButton,
            engine: .apple,
            language: .systemDefault
        )
        _ = try await coordinator.stageReleasedAudio(
            sessionID: session.id,
            chunks: [],
            releasedAt: releasedAt
        )
        _ = try await coordinator.persistProcessedText(sessionID: session.id, finalText: text)
    }

    func run(text: String) -> DictationRun {
        DictationRun(
            id: sessionID,
            date: releasedAt,
            engine: "Apple",
            audioSeconds: releasedAt.timeIntervalSince(startedAt),
            processSeconds: 0.25,
            text: text
        )
    }
}

private actor EventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor HistoryRecorder {
    private var runsByID: [UUID: DictationRun] = [:]
    var count: Int { runsByID.count }

    func appendIfAbsent(_ run: DictationRun) -> Bool {
        if let existing = runsByID[run.id] { return existing == run }
        runsByID[run.id] = run
        return true
    }
}

private extension RecordingSessionStatus {
    var phaseName: String {
        switch self {
        case .recording: "recording"
        case .readyForTranscription: "ready"
        case .processing: "processing"
        case .processed: "processed"
        case .failed: "failed"
        case .completed: "completed"
        case .cancelled: "cancelled"
        }
    }
}

@MainActor
private func withCoordinatorFixture(
    promoteSucceeds: Bool = true,
    _ body: @MainActor (CoordinatorFixture) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("murmure-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(CoordinatorFixture(root: root, promoteSucceeds: promoteSucceeds))
}
