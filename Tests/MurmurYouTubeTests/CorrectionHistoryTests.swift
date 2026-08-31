import Foundation
import MurmurDictionary
import Testing

@testable import MurmurYouTube

@Suite("Correction history")
struct CorrectionHistoryTests {
    @Test("modal correction input blocks button-driven dictation")
    @MainActor
    func modalCorrectionInputBlocksButtonRecording() {
        let controller = DictationController()

        #expect(controller.canStartButtonRecording)
        controller.suspendHotkeyForModalInput()
        #expect(!controller.canStartButtonRecording)
        controller.startButtonRecording()
        #expect(controller.state == .idle)
        controller.resumeHotkeyAfterModalInput()
        #expect(controller.canStartButtonRecording)
    }

    @Test("serialized persistence writes the append snapshot before the correction snapshot")
    @MainActor
    func serializedPersistenceOrdersAppendBeforeCorrection() async {
        let recorder = PersistenceRecorder(results: [true, true])
        let writer = SerializedPersistenceWriter()

        let appended = writer.enqueue { await recorder.write("append original") }
        let corrected = writer.enqueue { await recorder.write("rewrite corrected") }

        #expect(await appended.value)
        #expect(await corrected.value)
        #expect(await recorder.snapshots == ["append original", "rewrite corrected"])
    }

    @Test("failed correction persistence remains observable after prior append completes")
    @MainActor
    func serializedPersistenceReportsFailedCorrection() async {
        let recorder = PersistenceRecorder(results: [true, false])
        let writer = SerializedPersistenceWriter()

        let appended = writer.enqueue { await recorder.write("append original") }
        let corrected = writer.enqueue { await recorder.write("rewrite corrected") }

        #expect(await appended.value)
        #expect(!(await corrected.value))
        #expect(await recorder.snapshots == ["append original", "rewrite corrected"])
    }

    @Test("correction transactions never overlap while persistence is suspended")
    func correctionTransactionsAreSerialized() async {
        let coordinator = CorrectionTransactionCoordinator()
        let blocker = TransactionBlocker()
        let recorder = TransactionEventRecorder()

        let first = Task {
            await coordinator.perform {
                await recorder.record("first started")
                await blocker.wait()
                await recorder.record("first finished")
            }
        }
        await recorder.waitForEventCount(1)

        let second = Task {
            await coordinator.perform {
                await recorder.record("second started")
            }
        }
        await Task.yield()

        #expect(await recorder.events == ["first started"])
        await blocker.release()
        await first.value
        await second.value
        #expect(await recorder.events == ["first started", "first finished", "second started"])
    }

    @Test("a failed correction rollback restores only its own attempted run")
    func rollbackPreservesLaterCacheMutations() {
        let original = sampleRun()
        let attempted = original.correcting(
            intendedText: "Everything is a line.",
            inputMethod: .typed,
            rememberedRule: nil,
            at: Date(timeIntervalSince1970: 100)
        )
        let laterRun = DictationRun(
            date: Date(timeIntervalSince1970: 200),
            engine: "Parakeet",
            audioSeconds: 1,
            processSeconds: 1,
            text: "Later dictation"
        )

        let restored = RunLogCorrectionRollback.restore(
            attempted: attempted,
            original: original,
            in: [attempted, laterRun]
        )

        #expect(restored.first == original)
        #expect(restored.last == laterRun)
    }

    @Test("failed durable append removes only its attempted run")
    func failedAppendRollbackPreservesConcurrentRuns() {
        let attempted = sampleRun()
        let laterRun = DictationRun(
            date: Date(timeIntervalSince1970: 200),
            engine: "Parakeet",
            audioSeconds: 1,
            processSeconds: 1,
            text: "Later dictation"
        )

        #expect(
            RunLogAppendRollback.restore(attempted: attempted, in: [attempted, laterRun])
                == [laterRun]
        )
    }

    @Test("append rollback does nothing after the attempted run was superseded")
    func rollbackDoesNotOverwriteNewerMutation() {
        let attempted = sampleRun()
        var supersedingRun = attempted
        supersedingRun.text = "Newer corrected text"

        #expect(
            RunLogAppendRollback.restore(attempted: attempted, in: [supersedingRun])
                == [supersedingRun]
        )
    }

    @Test("durable append reports success only after persistence")
    @MainActor
    func durableAppendAwaitsPersistence() async {
        let run = sampleRun()
        let successfulState = RunCacheState()
        let successful = DurableRunAppendTransaction(
            persist: { _ in Task { true } },
            load: { successfulState.runs },
            store: { successfulState.runs = $0 }
        )

        #expect(await successful.record(run))
        #expect(successfulState.runs == [run])

        let failedState = RunCacheState()
        let failed = DurableRunAppendTransaction(
            persist: { _ in Task { false } },
            load: { failedState.runs },
            store: { failedState.runs = $0 }
        )

        #expect(!(await failed.record(run)))
        #expect(failedState.runs.isEmpty)
    }

    @Test("durable append is idempotent for the same run id and value")
    @MainActor
    func durableAppendIsIdempotent() async {
        let run = sampleRun()
        let state = RunCacheState()
        let transaction = DurableRunAppendTransaction(
            persist: { _ in
                state.persistCalls += 1
                return Task { true }
            },
            load: { state.runs },
            store: { state.runs = $0 }
        )

        #expect(await transaction.record(run))
        #expect(await transaction.record(run))
        #expect(state.runs == [run])
        #expect(state.persistCalls == 1)

        let conflictingState = RunCacheState()
        var conflicting = run
        conflicting.text = "Different value for the same ID"
        conflictingState.runs = [conflicting]
        let conflictTransaction = DurableRunAppendTransaction(
            persist: { _ in
                conflictingState.persistCalls += 1
                return Task { true }
            },
            load: { conflictingState.runs },
            store: { conflictingState.runs = $0 }
        )
        #expect(!(await conflictTransaction.record(run)))
        #expect(conflictingState.runs == [conflicting])
        #expect(conflictingState.persistCalls == 0)
    }

    @Test("durable replacement changes exactly one stable history id")
    @MainActor
    func durableReplacementChangesOneRun() async {
        let original = sampleRun()
        let unrelated = DictationRun(
            date: Date(timeIntervalSince1970: 200),
            engine: "Parakeet",
            audioSeconds: 2,
            processSeconds: 0.2,
            text: "Unrelated"
        )
        var replacement = original
        replacement.text = "Retranscribed"
        let state = RunCacheState(runs: [original, unrelated])
        let transaction = DurableRunReplacementTransaction(
            persist: { snapshot in
                state.persistedSnapshots.append(snapshot)
                return Task { true }
            },
            load: { state.runs },
            store: { state.runs = $0 }
        )

        #expect(await transaction.replace(id: original.id, with: replacement))
        #expect(state.runs == [replacement, unrelated])
        #expect(state.persistedSnapshots == [[replacement, unrelated]])
    }

    @Test("replacement rejects missing and mismatched ids without persistence")
    @MainActor
    func durableReplacementRejectsInvalidIdentity() async {
        let original = sampleRun()
        var replacement = original
        replacement.text = "Retranscribed"
        let state = RunCacheState(runs: [original])
        let transaction = DurableRunReplacementTransaction(
            persist: { _ in
                state.persistCalls += 1
                return Task { true }
            },
            load: { state.runs },
            store: { state.runs = $0 }
        )

        #expect(!(await transaction.replace(id: UUID(), with: replacement)))
        replacement.id = UUID()
        #expect(!(await transaction.replace(id: original.id, with: replacement)))
        #expect(state.runs == [original])
        #expect(state.persistCalls == 0)
    }

    @Test("failed replacement restores its row while retaining a concurrent append")
    @MainActor
    func failedReplacementPreservesConcurrentAppend() async {
        let original = sampleRun()
        var replacement = original
        replacement.text = "Retranscribed"
        let later = DictationRun(
            date: Date(timeIntervalSince1970: 300),
            engine: "Apple",
            audioSeconds: 1,
            processSeconds: 0.1,
            text: "Arrived during persistence"
        )
        let state = RunCacheState(runs: [original])
        let transaction = DurableRunReplacementTransaction(
            persist: { _ in
                state.runs.append(later)
                return Task { false }
            },
            load: { state.runs },
            store: { state.runs = $0 }
        )

        #expect(!(await transaction.replace(id: original.id, with: replacement)))
        #expect(state.runs == [original, later])
    }

    @Test("failed replacement never overwrites a newer mutation of the same id")
    @MainActor
    func failedReplacementPreservesSupersedingMutation() async {
        let original = sampleRun()
        var replacement = original
        replacement.text = "Retranscribed"
        var superseding = replacement
        superseding.text = "Corrected while persistence was pending"
        let state = RunCacheState(runs: [original])
        let transaction = DurableRunReplacementTransaction(
            persist: { _ in
                state.runs = [superseding]
                return Task { false }
            },
            load: { state.runs },
            store: { state.runs = $0 }
        )

        #expect(!(await transaction.replace(id: original.id, with: replacement)))
        #expect(state.runs == [superseding])
    }

    @Test("replacement rejects a stale expected run before persistence")
    @MainActor
    func replacementRejectsStaleExpectedValue() async {
        let expected = sampleRun()
        var current = expected
        current.text = "Corrected after preview"
        var replacement = expected
        replacement.text = "Stale retranscription"
        let state = RunCacheState(runs: [current])
        let transaction = DurableRunReplacementTransaction(
            persist: { _ in
                state.persistCalls += 1
                return Task { true }
            },
            load: { state.runs },
            store: { state.runs = $0 }
        )

        #expect(!(await transaction.replace(expected: expected, with: replacement)))
        #expect(state.runs == [current])
        #expect(state.persistCalls == 0)
    }

    @Test("a pending rule survives a history JSON round trip for later reconciliation")
    func pendingRuleJournalRoundTrip() throws {
        let suggestion = CorrectionRuleSuggestion(hear: "a lie", write: "a line")
        let run = sampleRun().correcting(
            intendedText: "Everything is a line.",
            inputMethod: .typed,
            rememberedRule: nil,
            pendingRule: suggestion,
            at: Date(timeIntervalSince1970: 100)
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmure-pending-rule-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(run).write(to: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(DictationRun.self, from: Data(contentsOf: url))

        #expect(PendingCorrectionRuleRecovery.pendingRules(in: [restored]) == [
            PendingCorrectionRule(
                runID: run.id,
                intendedText: "Everything is a line.",
                inputMethod: .typed,
                rule: suggestion
            )
        ])
    }

    @Test("pending recovery ignores a correction that was superseded before reconciliation")
    func pendingRecoveryIgnoresSupersededCorrection() {
        let oldRule = CorrectionRuleSuggestion(hear: "a lie", write: "a line")
        let pendingRun = sampleRun().correcting(
            intendedText: "Everything is a line.",
            inputMethod: .typed,
            rememberedRule: nil,
            pendingRule: oldRule,
            at: Date(timeIntervalSince1970: 100)
        )
        let supersedingRule = CorrectionRuleSuggestion(hear: "a lie", write: "a lane")
        let supersedingRun = pendingRun.correcting(
            intendedText: "Everything is a lane.",
            inputMethod: .typed,
            rememberedRule: nil,
            pendingRule: supersedingRule,
            at: Date(timeIntervalSince1970: 200)
        )
        let oldPending = PendingCorrectionRule(
            runID: pendingRun.id,
            intendedText: pendingRun.text,
            inputMethod: .typed,
            rule: oldRule
        )

        #expect(!PendingCorrectionRuleRecovery.isCurrent(oldPending, in: [supersedingRun]))
    }

    @Test("remembered saves require corrected history, dictionary, then metadata ordering")
    func rememberedSaveOrdering() {
        let suggestion = CorrectionRuleSuggestion(hear: "a lie", write: "a line")
        #expect(CorrectionSavePolicy.persistenceSteps(remember: true, suggestion: suggestion) == [
            .correctedHistory, .dictionary, .rememberedMetadata
        ])
        #expect(CorrectionSavePolicy.persistenceSteps(remember: false, suggestion: suggestion) == [
            .correctedHistory
        ])
        #expect(CorrectionSavePolicy.persistenceSteps(remember: true, suggestion: nil) == [
            .correctedHistory
        ])
    }

    @Test("a history-only correction can later be remembered without changing its text")
    func allowsRememberingExistingHistoryOnlyCorrection() {
        let run = sampleRun().correcting(
            intendedText: "Everything is a line.",
            inputMethod: .typed,
            rememberedRule: nil,
            at: Date(timeIntervalSince1970: 100)
        )
        let plan = CorrectionLearner.plan(
            heard: run.correction!.heardText,
            intended: run.text
        )

        #expect(CorrectionSavePolicy.canSave(
            draft: run.text,
            run: run,
            plan: plan,
            remember: true
        ))
        #expect(!CorrectionSavePolicy.canSave(
            draft: run.text,
            run: run,
            plan: plan,
            remember: false
        ))
    }

    @Test("an unchanged correction with its existing remembered rule cannot be saved again")
    func rejectsMeaninglessUnchangedSave() {
        let suggestion = CorrectionRuleSuggestion(hear: "a lie", write: "a line")
        let run = sampleRun().correcting(
            intendedText: "Everything is a line.",
            inputMethod: .typed,
            rememberedRule: suggestion,
            at: Date(timeIntervalSince1970: 100)
        )
        let plan = CorrectionLearner.plan(
            heard: run.correction!.heardText,
            intended: run.text
        )

        #expect(!CorrectionSavePolicy.canSave(
            draft: run.text,
            run: run,
            plan: plan,
            remember: true
        ))
    }

    @Test("legacy runs decode without a correction record")
    func legacyRunDecoding() throws {
        let json = """
            {
              "id": "CB533D44-B408-4B5D-9327-D687D44E7BC2",
              "date": "2026-08-29T12:00:00Z",
              "engine": "Apple",
              "audioSeconds": 1.5,
              "processSeconds": 0.25,
              "text": "Everything is a lie.",
              "audioFile": "Recordings/original.caf"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let run = try decoder.decode(DictationRun.self, from: Data(json.utf8))

        #expect(run.correction == nil)
        #expect(run.text == "Everything is a lie.")
    }

    @Test("repeated edits preserve the first heard text")
    func firstHeardTextIsStable() {
        let run = sampleRun()

        let first = run.correcting(
            intendedText: "Everything is a line.",
            inputMethod: .typed,
            rememberedRule: CorrectionRuleSuggestion(hear: "a lie", write: "a line"),
            at: Date(timeIntervalSince1970: 100)
        )
        let second = first.correcting(
            intendedText: "Everything is aligned.",
            inputMethod: .voiceAssisted,
            rememberedRule: nil,
            at: Date(timeIntervalSince1970: 200)
        )

        #expect(second.correction?.heardText == "Everything is a lie.")
        #expect(second.correction?.intendedText == "Everything is aligned.")
        #expect(second.text == "Everything is aligned.")
    }

    @Test("correction retains the original audio path")
    func audioPathIsRetained() {
        let corrected = sampleRun().correcting(
            intendedText: "Everything is a line.",
            inputMethod: .typed,
            rememberedRule: nil,
            at: Date(timeIntervalSince1970: 100)
        )

        #expect(corrected.audioFile == "Recordings/original.caf")
    }

    @Test("history stores a hear-write snapshot without a dictionary UUID")
    func rememberedRuleIsASnapshot() throws {
        let corrected = sampleRun().correcting(
            intendedText: "Everything is a line.",
            inputMethod: .typed,
            rememberedRule: CorrectionRuleSuggestion(hear: "a lie", write: "a line"),
            at: Date(timeIntervalSince1970: 100)
        )
        let encoded = try JSONEncoder().encode(corrected)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let correction = try #require(object["correction"] as? [String: Any])
        let rule = try #require(correction["rememberedRule"] as? [String: Any])

        #expect(rule["hear"] as? String == "a lie")
        #expect(rule["write"] as? String == "a line")
        #expect(rule["id"] == nil)
    }

    private func sampleRun() -> DictationRun {
        DictationRun(
            id: UUID(uuidString: "CB533D44-B408-4B5D-9327-D687D44E7BC2")!,
            date: Date(timeIntervalSince1970: 50),
            engine: "Apple",
            audioSeconds: 1.5,
            processSeconds: 0.25,
            text: "Everything is a lie.",
            audioFile: "Recordings/original.caf"
        )
    }
}

@MainActor
private final class RunCacheState {
    var runs: [DictationRun]
    var persistCalls = 0
    var persistedSnapshots: [[DictationRun]] = []

    init(runs: [DictationRun] = []) {
        self.runs = runs
    }
}

private actor PersistenceRecorder {
    private var remainingResults: [Bool]
    private(set) var snapshots: [String] = []

    init(results: [Bool]) {
        remainingResults = results
    }

    func write(_ snapshot: String) -> Bool {
        snapshots.append(snapshot)
        return remainingResults.removeFirst()
    }
}

private actor TransactionBlocker {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor TransactionEventRecorder {
    private(set) var events: [String] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record(_ event: String) {
        events.append(event)
        let ready = waiters.filter { events.count >= $0.0 }
        waiters.removeAll { events.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func waitForEventCount(_ count: Int) async {
        guard events.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}
