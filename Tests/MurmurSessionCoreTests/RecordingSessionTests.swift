import Foundation
import Testing
@testable import MurmurSessionCore

@Suite("Recording session")
struct RecordingSessionTests {
    @Test("released audio advances through processing and durable final text")
    func legalProcessingPath() throws {
        var session = RecordingSessionManifest.sample()
        try session.release(at: Date(timeIntervalSince1970: 20), audioFile: "audio.caf")
        try session.transition(to: .processing)
        try session.transition(to: .processed(finalText: "Bonjour tout le monde."))
        try session.transition(
            to: .completed(
                runID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            )
        )
        #expect(session.status.isCompleted)
    }

    @Test("a completed session cannot return to processing")
    func terminalCompletion() throws {
        var session = RecordingSessionManifest.sample()
        try session.release(at: Date(timeIntervalSince1970: 20), audioFile: "audio.caf")
        try session.transition(to: .processing)
        try session.transition(to: .processed(finalText: "Final"))
        try session.transition(to: .completed(runID: UUID()))
        #expect(throws: RecordingSessionTransitionError.self) {
            try session.transition(to: .processing)
        }
    }

    @Test("manifest survives a JSON round trip")
    func jsonRoundTrip() throws {
        var session = RecordingSessionManifest.sample()
        try session.release(at: Date(timeIntervalSince1970: 20), audioFile: "audio.caf")
        let data = try JSONEncoder.sessionEncoder.encode(session)
        let decoded = try JSONDecoder.sessionDecoder.decode(
            RecordingSessionManifest.self,
            from: data
        )
        #expect(decoded == session)
    }

    @Test("audio staging failure is durable and retryable")
    func failureAndRetry() throws {
        var session = RecordingSessionManifest.sample()
        let failure = RecordingFailure(stage: .audioStaging, message: "Disk unavailable")

        try session.transition(to: .failed(failure))
        #expect(session.status == .failed(failure))

        try session.transition(to: .processing)
        #expect(session.status == .processing)
    }

    @Test("a cancelled session is terminal")
    func terminalCancellation() throws {
        var session = RecordingSessionManifest.sample()
        try session.transition(to: .cancelled)

        #expect(throws: RecordingSessionTransitionError.self) {
            try session.transition(to: .processing)
        }
    }

    @Test("processed text cannot be empty")
    func rejectsEmptyFinalText() throws {
        var session = RecordingSessionManifest.sample()
        try session.release(at: Date(timeIntervalSince1970: 20), audioFile: "audio.caf")
        try session.transition(to: .processing)

        #expect(throws: RecordingSessionTransitionError.self) {
            try session.transition(to: .processed(finalText: "   "))
        }
    }

    @Test("released audio filename cannot be empty")
    func rejectsEmptyAudioFilename() {
        var session = RecordingSessionManifest.sample()

        #expect(throws: RecordingSessionTransitionError.self) {
            try session.release(at: Date(timeIntervalSince1970: 20), audioFile: "  ")
        }
    }
}

private extension RecordingSessionManifest {
    static func sample() -> Self {
        RecordingSessionManifest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            startedAt: Date(timeIntervalSince1970: 10),
            trigger: .mainButton,
            engine: .apple,
            language: .locale(identifier: "fr-FR")
        )
    }
}
