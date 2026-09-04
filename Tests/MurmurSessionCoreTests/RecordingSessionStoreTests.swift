import Foundation
import Testing
@testable import MurmurSessionCore

@Suite("Recording session store")
struct RecordingSessionStoreTests {
    @Test("create writes an atomic manifest that a new store can load")
    func createAndReload() async throws {
        try await withTemporaryStore { root, store in
            let session = RecordingSessionManifest.storeSample()
            try await store.create(session)

            let reloaded = RecordingSessionStore(rootURL: root)
            #expect(try await reloaded.load(id: session.id) == session)
        }
    }

    @Test("recoverable sessions exclude completed and cancelled manifests")
    func recoveryFilter() async throws {
        try await withTemporaryStore { _, store in
            let recoverable = RecordingSessionManifest.storeSample(
                id: uuid("00000000-0000-0000-0000-000000000001"),
                startedAt: Date(timeIntervalSince1970: 1),
                status: .readyForTranscription
            )
            let completed = RecordingSessionManifest.storeSample(
                id: uuid("00000000-0000-0000-0000-000000000002"),
                startedAt: Date(timeIntervalSince1970: 2),
                status: .completed(runID: UUID())
            )
            let cancelled = RecordingSessionManifest.storeSample(
                id: uuid("00000000-0000-0000-0000-000000000003"),
                startedAt: Date(timeIntervalSince1970: 3),
                status: .cancelled
            )
            try await store.create(completed)
            try await store.create(cancelled)
            try await store.create(recoverable)

            #expect(try await store.recoverableSessions() == [recoverable])
        }
    }

    @Test("repeating completion with the same run id is idempotent")
    func completionIsIdempotent() async throws {
        try await withTemporaryStore { _, store in
            let session = RecordingSessionManifest.storeSample(status: .processed(finalText: "Final"))
            let runID = uuid("00000000-0000-0000-0000-000000000099")
            try await store.create(session)

            let first = try await store.markCompleted(id: session.id, runID: runID)
            let second = try await store.markCompleted(id: session.id, runID: runID)

            #expect(first == second)
            #expect(second.status == .completed(runID: runID))
        }
    }

    @Test("completion with a different run id is rejected")
    func conflictingCompletionIsRejected() async throws {
        try await withTemporaryStore { _, store in
            let firstRun = uuid("00000000-0000-0000-0000-000000000098")
            let session = RecordingSessionManifest.storeSample(status: .completed(runID: firstRun))
            try await store.create(session)

            await #expect(throws: RecordingSessionStoreError.self) {
                try await store.markCompleted(id: session.id, runID: UUID())
            }
        }
    }

    @Test("a malformed manifest does not hide valid recoverable sessions")
    func malformedManifestIsolation() async throws {
        try await withTemporaryStore { root, store in
            let valid = RecordingSessionManifest.storeSample(status: .readyForTranscription)
            try await store.create(valid)

            let malformedDirectory = root.appendingPathComponent("malformed", isDirectory: true)
            try FileManager.default.createDirectory(
                at: malformedDirectory,
                withIntermediateDirectories: true
            )
            try Data("not json".utf8).write(
                to: malformedDirectory.appendingPathComponent("manifest.json")
            )

            #expect(try await store.recoverableSessions() == [valid])
        }
    }

    @Test("store-generated audio paths remain below the normalized root")
    func stagedAudioPathIsContained() async {
        let suppliedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("parent", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("safe", isDirectory: true)
        let store = RecordingSessionStore(rootURL: suppliedRoot)
        let audioURL = await store.stagedAudioURL(
            for: uuid("00000000-0000-0000-0000-000000000010")
        )

        #expect(audioURL.deletingLastPathComponent().deletingLastPathComponent() == suppliedRoot.standardizedFileURL)
        #expect(audioURL.lastPathComponent == "audio.caf")
    }

    @Test("an incomplete session cannot be deleted")
    func incompleteSessionIsNotDeleted() async throws {
        try await withTemporaryStore { _, store in
            let session = RecordingSessionManifest.storeSample(status: .readyForTranscription)
            try await store.create(session)

            await #expect(throws: RecordingSessionStoreError.self) {
                try await store.removeCompletedSession(id: session.id)
            }
            #expect(try await store.load(id: session.id) == session)
        }
    }

    @Test("discard removes a recoverable session directory and its audio")
    func discardRecoverableSession() async throws {
        try await withTemporaryStore { _, store in
            let session = RecordingSessionManifest.storeSample(status: .readyForTranscription)
            try await store.create(session)
            try Data("audio".utf8).write(to: await store.stagedAudioURL(for: session.id))

            try await store.discardRecoverableSession(id: session.id)

            await #expect(throws: RecordingSessionStoreError.self) {
                try await store.load(id: session.id)
            }
        }
    }

    @Test("discard refuses a completed session")
    func completedSessionIsNotDiscardedAsRecovery() async throws {
        try await withTemporaryStore { _, store in
            let session = RecordingSessionManifest.storeSample(
                status: .completed(runID: UUID())
            )
            try await store.create(session)

            await #expect(throws: RecordingSessionStoreError.self) {
                try await store.discardRecoverableSession(id: session.id)
            }
            #expect(try await store.load(id: session.id) == session)
        }
    }
}

private func withTemporaryStore(
    _ body: (URL, RecordingSessionStore) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("murmure-session-store-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root, RecordingSessionStore(rootURL: root))
}

private func uuid(_ string: String) -> UUID {
    UUID(uuidString: string)!
}

private extension RecordingSessionManifest {
    static func storeSample(
        id: UUID = uuid("00000000-0000-0000-0000-000000000010"),
        startedAt: Date = Date(timeIntervalSince1970: 10),
        status: RecordingSessionStatus = .recording
    ) -> Self {
        RecordingSessionManifest(
            id: id,
            startedAt: startedAt,
            trigger: .mainButton,
            engine: .apple,
            language: .systemDefault,
            releasedAt: status == .recording ? nil : Date(timeIntervalSince1970: 20),
            audioFile: status == .recording ? nil : "audio.caf",
            status: status
        )
    }
}
