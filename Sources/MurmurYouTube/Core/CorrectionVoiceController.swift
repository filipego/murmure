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
        var canStop: Bool { self == .starting || self == .listening }
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
    private var cancellationRequested = false

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
        cancellationRequested = false
        state = .starting

        Task { @MainActor in
            guard await Permissions.requestMicrophone() else {
                fail(
                    "Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.",
                    sessionID: id
                )
                return
            }
            guard sessionID == id, state == .starting else { return }

            do {
                let engine = makeEngine()
                self.engine = engine
                let chunks = try await engine.start()
                guard sessionID == id, state == .starting else {
                    await engine.finish()
                    return
                }
                guard let format = await engine.preferredInputFormat() else {
                    throw TranscriptionError.noAudioFormat
                }
                let liveInput = try LiveAudioInputResolver.resolve(
                    Settings.shared.microphoneSelection
                )
                guard sessionID == id, state == .starting else {
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
                    deviceID: liveInput.objectID,
                    outputFormat: format,
                    onBuffer: { continuation.yield($0) },
                    onLevel: { _ in },
                    onDeviceChange: { [weak self] in
                        Task { @MainActor in
                            self?.fail(
                                "\(liveInput.device.displayName) changed or disconnected.",
                                sessionID: id
                            )
                        }
                    }
                )
                guard sessionID == id, state == .starting else {
                    finish(.cancelled, sessionID: id)
                    return
                }

                state = .listening
                consumeTask = Task { @MainActor in
                    do {
                        for try await chunk in chunks where self.sessionID == id {
                            self.transcript = chunk.text
                        }
                    } catch {
                        let message = error.localizedDescription
                        self.streamFailure = message
                        Task { @MainActor [weak self] in
                            self?.finish(.failure(message), sessionID: id)
                        }
                    }
                }
            } catch {
                fail(error.localizedDescription, sessionID: id)
            }
        }
    }

    func stop() {
        guard let id = sessionID else { return }
        guard state == .starting || state == .listening else { return }
        finish(state == .starting ? .cancelled : .stopped, sessionID: id)
    }

    func cancel() {
        guard let id = sessionID else { return }
        if state == .finishing {
            cancellationRequested = true
            return
        }
        finish(.cancelled, sessionID: id)
    }

    private enum FinishReason {
        case stopped
        case failure(String)
        case cancelled
    }

    private func fail(_ message: String, sessionID id: UUID) {
        finish(.failure(message), sessionID: id)
    }

    private func finish(_ reason: FinishReason, sessionID id: UUID) {
        guard sessionID == id, state != .finishing else { return }
        state = .finishing
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        let feedTask = self.feedTask
        self.feedTask = nil
        let consumeTask = self.consumeTask
        self.consumeTask = nil
        let engine = self.engine
        self.engine = nil

        if case .cancelled = reason {
            feedTask?.cancel()
            consumeTask?.cancel()
        }

        Task { @MainActor in
            await feedTask?.value
            await engine?.finish()
            await consumeTask?.value
            guard sessionID == id else { return }

            if cancellationRequested {
                complete(.cancelled, sessionID: id)
                return
            }

            switch reason {
            case .stopped:
                if let streamFailure {
                    complete(.failure(streamFailure), sessionID: id)
                } else if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    complete(.blankAudio, sessionID: id)
                } else {
                    complete(.transcript(transcript), sessionID: id)
                }
            case .failure(let message):
                complete(.failure(message), sessionID: id)
            case .cancelled:
                complete(.cancelled, sessionID: id)
            }
        }
    }

    private func complete(_ outcome: Outcome, sessionID id: UUID) {
        guard sessionID == id else { return }
        let completion = self.completion
        self.completion = nil
        sessionID = nil
        state = .idle
        transcript = ""
        streamFailure = nil
        cancellationRequested = false
        completion?(outcome)
    }
}
