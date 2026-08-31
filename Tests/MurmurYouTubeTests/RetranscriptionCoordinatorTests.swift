import Foundation
import MurmurDictionary
import MurmurSessionCore
import Testing
@testable import MurmurYouTube

@Suite("Retranscription coordinator")
@MainActor
struct RetranscriptionCoordinatorTests {
    @Test("history preview is pure and confirmation preserves identity audio and first heard text")
    func historyPreviewAndConfirmation() async throws {
        let state = RetranscriptionTestState()
        let now = Date(timeIntervalSince1970: 500)
        let coordinator = RetranscriptionCoordinator(
            dependencies: dependencies(state: state, now: now)
        )
        let source = historyRun().correcting(
            intendedText: "Previously corrected",
            inputMethod: .typed,
            rememberedRule: CorrectionRuleSuggestion(hear: "raw", write: "corrected"),
            at: Date(timeIntervalSince1970: 200)
        )

        let preview = try await coordinator.preview(source: .history(source), engine: .parakeet)

        #expect(preview.rawText == "raw archived words")
        #expect(preview.candidateText == "Dictionary result")
        #expect(preview.engine == .parakeet)
        #expect(await state.events == ["transcribe:parakeet", "format", "correct"])
        #expect(await state.replacements.isEmpty)

        #expect(await coordinator.confirm(preview))
        let replacements = await state.replacements
        let saved = try #require(replacements.first?.replacement)
        #expect(replacements.first?.expected == source)
        #expect(saved.id == source.id)
        #expect(saved.date == source.date)
        #expect(saved.audioSeconds == source.audioSeconds)
        #expect(saved.audioFile == source.audioFile)
        #expect(saved.engine == "Parakeet")
        #expect(saved.processSeconds == 0.75)
        #expect(saved.text == "Dictionary result")
        #expect(saved.correction?.heardText == "Original heard words")
        #expect(saved.correction?.intendedText == "Dictionary result")
        #expect(saved.correction?.inputMethod == .retranscription)
        #expect(saved.correction?.rememberedRule == source.correction?.rememberedRule)
        #expect(saved.correction?.correctedAt == now)
        #expect(await state.events == ["transcribe:parakeet", "format", "correct", "replace"])
    }

    @Test("failed recording confirmation persists then completes without insertion")
    func failedRecordingConfirmation() async throws {
        let state = RetranscriptionTestState()
        let coordinator = RetranscriptionCoordinator(dependencies: dependencies(state: state))
        let failure = RecordingFailure(stage: .transcription, message: "No words")
        let recording = RecoverableRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000091")!,
            startedAt: Date(timeIntervalSince1970: 10),
            releasedAt: Date(timeIntervalSince1970: 14),
            trigger: .mainButton,
            engine: .apple,
            language: .systemDefault,
            status: .failed(failure),
            audioURL: URL(fileURLWithPath: "/tmp/recoverable.caf"),
            failure: failure
        )

        let preview = try await coordinator.preview(source: .recoverable(recording), engine: .apple)
        #expect(await coordinator.confirm(preview))

        let persisted = await state.persisted
        #expect(persisted.count == 1)
        #expect(persisted[0].0 == recording.id)
        #expect(persisted[0].1 == "Dictionary result")
        let completed = await state.completed
        #expect(completed.count == 1)
        #expect(completed[0].id == recording.id)
        #expect(completed[0].text == "Dictionary result")
        #expect(completed[0].audioSeconds == 4)
        #expect(completed[0].engine == "Apple")
        #expect(await state.refreshCount == 1)
        #expect(await state.events == [
            "transcribe:apple", "format", "correct", "persist", "complete", "refresh"
        ])
    }

    @Test("cancelled and stale previews cannot write")
    func cancellationAndStalePreview() async throws {
        let state = RetranscriptionTestState()
        let coordinator = RetranscriptionCoordinator(dependencies: dependencies(state: state))
        let source = RetranscriptionSource.history(historyRun())

        let cancelled = try await coordinator.preview(source: source, engine: .apple)
        coordinator.cancel()
        #expect(!(await coordinator.confirm(cancelled)))

        let stale = try await coordinator.preview(source: source, engine: .apple)
        let current = try await coordinator.preview(source: source, engine: .parakeet)
        #expect(!(await coordinator.confirm(stale)))
        #expect(await coordinator.confirm(current))

        #expect(await state.replacements.count == 1)
        #expect(await state.events.filter { $0 == "replace" }.count == 1)
    }

    @Test("failed persistence keeps the current preview retryable")
    func failedConfirmationCanRetry() async throws {
        let state = RetranscriptionTestState(replacementResults: [false, true])
        let coordinator = RetranscriptionCoordinator(dependencies: dependencies(state: state))
        let preview = try await coordinator.preview(source: .history(historyRun()), engine: .apple)

        #expect(!(await coordinator.confirm(preview)))
        #expect(await coordinator.confirm(preview))
        #expect(await state.replacements.count == 2)
    }

    private func dependencies(
        state: RetranscriptionTestState,
        now: Date = Date(timeIntervalSince1970: 400)
    ) -> RetranscriptionDependencies {
        RetranscriptionDependencies(
            transcribe: { url, engine in
                await state.record("transcribe:\(engine.rawValue)")
                await state.recordTranscribedURL(url)
                return ArchivedTranscription(text: "raw archived words", processSeconds: 0.75)
            },
            format: { raw in
                await state.record("format")
                #expect(raw == "raw archived words")
                return "Formatted words"
            },
            correct: { formatted in
                await state.record("correct")
                #expect(formatted == "Formatted words")
                return ("Dictionary result", [])
            },
            replaceHistory: { expected, replacement in
                await state.record("replace")
                return await state.replace(expected: expected, replacement: replacement)
            },
            persistProcessed: { id, text in
                await state.record("persist")
                await state.persist(id: id, text: text)
            },
            completeRecovered: { _, run in
                await state.record("complete")
                return await state.complete(run)
            },
            refreshRecoverables: {
                await state.record("refresh")
                await state.refresh()
            },
            now: { now }
        )
    }

    private func historyRun() -> DictationRun {
        DictationRun(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000090")!,
            date: Date(timeIntervalSince1970: 100),
            engine: "Apple",
            audioSeconds: 3,
            processSeconds: 0.2,
            text: "Original heard words",
            audioFile: "Recordings/original.caf"
        )
    }
}

private actor RetranscriptionTestState {
    struct Replacement: Sendable {
        let expected: DictationRun
        let replacement: DictationRun
    }

    private(set) var events: [String] = []
    private(set) var replacements: [Replacement] = []
    private(set) var persisted: [(UUID, String)] = []
    private(set) var completed: [DictationRun] = []
    private(set) var refreshCount = 0
    var transcribedURLs: [URL] = []
    private var replacementResults: [Bool]

    init(replacementResults: [Bool] = [true]) {
        self.replacementResults = replacementResults
    }

    func record(_ event: String) {
        events.append(event)
    }

    func recordTranscribedURL(_ url: URL) {
        transcribedURLs.append(url)
    }

    func replace(expected: DictationRun, replacement: DictationRun) -> Bool {
        replacements.append(Replacement(expected: expected, replacement: replacement))
        return replacementResults.isEmpty ? true : replacementResults.removeFirst()
    }

    func persist(id: UUID, text: String) {
        persisted.append((id, text))
    }

    func complete(_ run: DictationRun) -> Bool {
        completed.append(run)
        return true
    }

    func refresh() {
        refreshCount += 1
    }
}
