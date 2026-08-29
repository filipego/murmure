import Foundation
import Observation

@MainActor
@Observable
final class CorrectionVoiceController {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case finishing

        var isBusy: Bool { self != .idle }
        var isRecording: Bool { self == .listening }
    }

    enum Outcome: Equatable, Sendable {
        case transcript(String)
        case blankAudio
        case failure(String)
        case cancelled
    }

    private(set) var state: State = .idle
    private var transcript = ""

    private let capture = AudioCapture()
    private let makeEngine: @Sendable () -> any TranscriptionEngine
    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?
    private var completion: (@MainActor (Outcome) -> Void)?
    private var sessionID: UUID?
    private var streamFailure: String?

    init(makeEngine: @escaping @Sendable () -> any TranscriptionEngine = engineForCurrentSetting) {
        self.makeEngine = makeEngine
    }

    func start(completion: @escaping @MainActor (Outcome) -> Void) {
        guard state == .idle else { return }
        let id = UUID()
        sessionID = id
        self.completion = completion
        transcript = ""
        streamFailure = nil
        state = .starting

        Task { @MainActor in
            guard await Permissions.requestMicrophone() else {
                await fail(
                    "Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.",
                    sessionID: id
                )
                return
            }
            guard sessionID == id else { return }

            do {
                let engine = makeEngine()
                self.engine = engine
                let chunks = try await engine.start()
                guard sessionID == id else {
                    await engine.finish()
                    return
                }
                guard let format = await engine.preferredInputFormat() else {
                    throw TranscriptionError.noAudioFormat
                }
                guard sessionID == id else {
                    await engine.finish()
                    return
                }

                let (audioStream, continuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .unbounded
                )
                audioContinuation = continuation
                feedTask = Task.detached(priority: .userInitiated) {
                    for await chunk in audioStream {
                        await engine.feed(chunk)
                    }
                }

                try capture.start(
                    outputFormat: format,
                    onBuffer: { continuation.yield($0) },
                    onLevel: { _ in }
                )
                guard sessionID == id, state == .starting else {
                    await teardown(sessionID: id)
                    return
                }

                state = .listening
                consumeTask = Task { @MainActor in
                    do {
                        for try await chunk in chunks where self.sessionID == id {
                            self.transcript = chunk.text
                        }
                    } catch {
                        self.streamFailure = error.localizedDescription
                    }
                }
            } catch {
                await fail(error.localizedDescription, sessionID: id)
            }
        }
    }

    func stop() {
        guard state == .listening, let id = sessionID else { return }
        state = .finishing
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil

        Task { @MainActor in
            await feedTask?.value
            feedTask = nil
            await engine?.finish()
            await consumeTask?.value
            consumeTask = nil
            engine = nil
            guard sessionID == id else { return }
            if let streamFailure {
                complete(.failure(streamFailure), sessionID: id)
            } else if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                complete(.blankAudio, sessionID: id)
            } else {
                complete(.transcript(transcript), sessionID: id)
            }
        }
    }

    func cancel() {
        guard let id = sessionID else { return }
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil
        let engine = self.engine
        self.engine = nil
        Task { await engine?.finish() }
        complete(.cancelled, sessionID: id)
    }

    private func fail(_ message: String, sessionID id: UUID) async {
        guard sessionID == id else { return }
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil
        let engine = self.engine
        self.engine = nil
        await engine?.finish()
        complete(.failure(message), sessionID: id)
    }

    private func teardown(sessionID id: UUID) async {
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        await feedTask?.value
        feedTask = nil
        await engine?.finish()
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        guard sessionID == id else { return }
        complete(.cancelled, sessionID: id)
    }

    private func complete(_ outcome: Outcome, sessionID id: UUID) {
        guard sessionID == id else { return }
        let completion = self.completion
        self.completion = nil
        sessionID = nil
        state = .idle
        transcript = ""
        streamFailure = nil
        completion?(outcome)
    }
}
