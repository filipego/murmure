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
