import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class LocalCommandController {
    private(set) var state: LocalCommandReviewState = .idle
    private(set) var level: Float = 0
    private(set) var instructionTranscript = ""
    private(set) var sourceApplicationName: String?

    var isBusy: Bool {
        switch state {
        case .recordingInstruction, .processing:
            true
        case .idle, .review, .failed:
            false
        }
    }

    private let capture = AudioCapture()
    private let transformer = FoundationLocalCommandTransformer()
    private var selectedCapture: SelectedTextCapture?
    private var engine: (any TranscriptionEngine)?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var consumeTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var finalizeTask: Task<Void, Never>?
    private var operationID = UUID()
    private var isRecordingReady = false
    private var finishRequested = false
    private var isFinalizing = false

    func begin() {
        guard LocalCommandPolicy.canBegin(from: state) else { return }
        if let reason = FoundationLocalCommandTransformer.unavailableReason {
            fail("Command Mode is local-only. \(reason)")
            return
        }

        do {
            let selectedCapture = try SelectedTextService.capture()
            guard selectedCapture.text.count <= LocalCommandPolicy.maximumSelectedCharacters else {
                fail("The selection is too long for local Command Mode. Your text was not changed.")
                return
            }
            self.selectedCapture = selectedCapture
            sourceApplicationName = selectedCapture.sourceApplicationName
        } catch {
            fail(error.localizedDescription)
            return
        }

        instructionTranscript = ""
        level = 0
        operationID = UUID()
        let operationID = operationID
        finishRequested = false
        isRecordingReady = false
        isFinalizing = false
        state = .recordingInstruction

        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == operationID { self.setupTask = nil }
            }
            do {
                guard await Permissions.requestMicrophone() else {
                    self.fail(
                        "Microphone access is required to dictate a Command Mode instruction.",
                        operationID: operationID
                    )
                    return
                }
                guard self.operationID == operationID, !Task.isCancelled else { return }

                let settings = Settings.shared
                let engine = makeTranscriptionEngine(
                    choice: settings.engine,
                    language: settings.transcriptionLanguage.selection
                )
                let transcriptChunks = try await engine.start()
                guard self.operationID == operationID, !Task.isCancelled else {
                    await engine.finish()
                    return
                }
                self.engine = engine
                guard let format = await engine.preferredInputFormat() else {
                    throw TranscriptionError.noAudioFormat
                }
                let input = try LiveAudioInputResolver.resolve(settings.microphoneSelection)
                let (audioStream, continuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .unbounded
                )
                audioContinuation = continuation
                feedTask = Task.detached(priority: .userInitiated) {
                    for await chunk in audioStream { await engine.feed(chunk) }
                }
                consumeTask = Task { @MainActor [weak self] in
                    do {
                        for try await chunk in transcriptChunks {
                            guard let self, self.operationID == operationID else { return }
                            self.instructionTranscript = chunk.text
                        }
                    } catch {
                        self?.fail(
                            "The spoken instruction could not be transcribed.",
                            operationID: operationID
                        )
                    }
                }

                try capture.start(
                    deviceID: input.objectID,
                    outputFormat: format,
                    onBuffer: { continuation.yield($0) },
                    onLevel: { [weak self] value in
                        Task { @MainActor in
                            guard let self, self.operationID == operationID else { return }
                            self.level = value
                        }
                    },
                    onDeviceChange: { [weak self] in
                        Task { @MainActor in
                            self?.fail(
                                "The selected microphone became unavailable.",
                                operationID: operationID
                            )
                        }
                    }
                )
                guard self.operationID == operationID, !Task.isCancelled else {
                    self.teardownRecording()
                    return
                }
                isRecordingReady = true
                if finishRequested { finalizeRecording(operationID: operationID) }
            } catch {
                self.fail(error.localizedDescription, operationID: operationID)
            }
        }
    }

    func finish() {
        guard state == .recordingInstruction else { return }
        finishRequested = true
        state = .processing
        if isRecordingReady { finalizeRecording(operationID: operationID) }
    }

    func updateProposal(_ proposal: String) {
        guard case let .review(original, _, _) = state else { return }
        state = .review(original: original, proposed: proposal)
    }

    func replaceProposal() -> SelectedTextReplacementResult {
        guard case let .review(original, proposed, _) = state,
              let target = selectedCapture?.target,
              let validated = LocalCommandPolicy.validatedProposal(proposed)
        else { return .failed }

        let result = target.replaceIfUnchanged(original: original, with: validated)
        if result == .replaced {
            reset()
        } else {
            state = LocalCommandPolicy.reviewState(
                after: result,
                original: original,
                proposed: proposed
            )
        }
        return result
    }

    func copyProposal() -> Bool {
        guard case let .review(_, proposed, _) = state,
              let validated = LocalCommandPolicy.validatedProposal(proposed)
        else { return false }
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(validated, forType: .string)
        if copied { reset() }
        return copied
    }

    func cancel() {
        teardownRecording()
        reset()
    }

    func reset() {
        operationID = UUID()
        state = .idle
        level = 0
        instructionTranscript = ""
        sourceApplicationName = nil
        selectedCapture = nil
        finishRequested = false
        isRecordingReady = false
        isFinalizing = false
    }

    private func finalizeRecording(operationID: UUID) {
        guard self.operationID == operationID, !isFinalizing else { return }
        isFinalizing = true
        capture.stop()
        level = 0
        audioContinuation?.finish()
        audioContinuation = nil

        finalizeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await feedTask?.value
            feedTask = nil
            await engine?.finish()
            await consumeTask?.value
            consumeTask = nil
            engine = nil
            guard self.operationID == operationID, !Task.isCancelled else { return }

            let instruction = instructionTranscript.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard let selectedCapture,
                  !instruction.isEmpty else {
                fail(
                    "No spoken instruction was recognized. Your selected text was not changed.",
                    operationID: operationID
                )
                return
            }
            let request = LocalCommandRequest(
                selectedText: selectedCapture.text,
                instruction: instruction,
                sourceApplicationName: selectedCapture.sourceApplicationName
            )
            do {
                let proposal = try await transformer.transform(request)
                guard self.operationID == operationID, !Task.isCancelled else { return }
                state = .review(original: request.selectedText, proposed: proposal)
                finalizeTask = nil
                isFinalizing = false
            } catch {
                fail(error.localizedDescription, operationID: operationID)
            }
        }
    }

    private func fail(_ message: String, operationID: UUID? = nil) {
        if let operationID, self.operationID != operationID { return }
        self.operationID = UUID()
        teardownRecording()
        state = .failed(message)
        level = 0
        finishRequested = false
        isRecordingReady = false
        isFinalizing = false
    }

    private func teardownRecording() {
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil
        setupTask?.cancel()
        setupTask = nil
        finalizeTask?.cancel()
        finalizeTask = nil
        let engine = self.engine
        self.engine = nil
        Task { await engine?.finish() }
    }
}
