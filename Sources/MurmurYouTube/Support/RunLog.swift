import MurmurDictionary
import MurmurSessionCore
import Foundation

struct TranscriptCorrectionRecord: Codable, Equatable, Sendable {
    enum InputMethod: String, Codable, Equatable, Sendable {
        case typed
        case voiceAssisted
        case retranscription
    }

    let heardText: String
    let intendedText: String
    let correctedAt: Date
    let inputMethod: InputMethod
    let rememberedRule: CorrectionRuleSuggestion?
    /// Durable handoff to dictionary persistence. It is promoted to `rememberedRule` only
    /// after both files confirm their writes, and is retried automatically after hydration.
    let pendingRule: CorrectionRuleSuggestion?
}

/// A dictionary rule whose correction is durable but whose dictionary/history completion has
/// not finished yet. The correction record itself is the transaction journal, so recovery never
/// needs a second external file.
struct PendingCorrectionRule: Equatable, Sendable {
    let runID: UUID
    let intendedText: String
    let inputMethod: TranscriptCorrectionRecord.InputMethod
    let rule: CorrectionRuleSuggestion
}

enum PendingCorrectionRuleRecovery {
    static func pendingRules(in runs: [DictationRun]) -> [PendingCorrectionRule] {
        runs.compactMap { run in
            guard let correction = run.correction,
                  let rule = correction.pendingRule else {
                return nil
            }
            return PendingCorrectionRule(
                runID: run.id,
                intendedText: correction.intendedText,
                inputMethod: correction.inputMethod,
                rule: rule
            )
        }
    }

    static func isCurrent(_ pending: PendingCorrectionRule, in runs: [DictationRun]) -> Bool {
        guard let correction = runs.first(where: { $0.id == pending.runID })?.correction else {
            return false
        }
        return correction.intendedText == pending.intendedText
            && correction.inputMethod == pending.inputMethod
            && correction.pendingRule == pending.rule
    }
}

enum RunLogCorrectionRollback {
    /// Restores only the failed attempt when it has not been superseded, retaining unrelated
    /// cache changes that happened while the external write was in flight.
    static func restore(
        attempted: DictationRun,
        original: DictationRun,
        in runs: [DictationRun]
    ) -> [DictationRun] {
        guard let index = runs.firstIndex(where: { $0.id == attempted.id }),
              runs[index] == attempted else {
            return runs
        }
        var restored = runs
        restored[index] = original
        return restored
    }
}

enum RunLogAppendRollback {
    /// Removes only the failed append when that exact run is still present. A correction or
    /// other mutation with the same ID supersedes the attempted value and must be preserved.
    static func restore(attempted: DictationRun, in runs: [DictationRun]) -> [DictationRun] {
        guard let index = runs.firstIndex(where: { $0.id == attempted.id }),
              runs[index] == attempted else {
            return runs
        }
        var restored = runs
        restored.remove(at: index)
        return restored
    }
}

enum RunLogReplacementRollback {
    /// Restores only the exact failed replacement. If the same run was corrected or replaced
    /// again while persistence was pending, that newer value wins and remains untouched.
    static func restore(
        attempted: DictationRun,
        original: DictationRun,
        in runs: [DictationRun]
    ) -> [DictationRun] {
        guard let index = runs.firstIndex(where: { $0.id == attempted.id }),
              runs[index] == attempted else {
            return runs
        }
        var restored = runs
        restored[index] = original
        return restored
    }
}

@MainActor
struct DurableRunAppendTransaction {
    let persist: (DictationRun) -> Task<Bool, Never>
    let load: () -> [DictationRun]
    let store: ([DictationRun]) -> Void

    func record(_ run: DictationRun) async -> Bool {
        var appended = load()
        if let existing = appended.first(where: { $0.id == run.id }) {
            return existing == run
        }
        appended.append(run)
        store(appended)

        guard await persist(run).value else {
            let current = load()
            let rolledBack = RunLogAppendRollback.restore(attempted: run, in: current)
            if rolledBack != current { store(rolledBack) }
            return false
        }
        return true
    }
}

@MainActor
struct DurableRunReplacementTransaction {
    let persist: ([DictationRun]) -> Task<Bool, Never>
    let load: () -> [DictationRun]
    let store: ([DictationRun]) -> Void

    func replace(id: UUID, with replacement: DictationRun) async -> Bool {
        await replace(id: id, expected: nil, with: replacement)
    }

    func replace(expected: DictationRun, with replacement: DictationRun) async -> Bool {
        await replace(id: expected.id, expected: expected, with: replacement)
    }

    private func replace(
        id: UUID,
        expected: DictationRun?,
        with replacement: DictationRun
    ) async -> Bool {
        guard replacement.id == id else { return false }
        let originalRuns = load()
        guard let index = originalRuns.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if let expected, originalRuns[index] != expected { return false }

        let original = originalRuns[index]
        var attemptedRuns = originalRuns
        attemptedRuns[index] = replacement
        store(attemptedRuns)

        guard await persist(attemptedRuns).value else {
            let current = load()
            let rolledBack = RunLogReplacementRollback.restore(
                attempted: replacement,
                original: original,
                in: current
            )
            if rolledBack != current { store(rolledBack) }
            return false
        }
        return true
    }
}

enum CorrectionSaveResult: Equatable, Sendable {
    case saved
    case historyFailed
    case rulePending
    case rememberedMetadataPending
}

/// One completed dictation.
struct DictationRun: Codable, Equatable, Sendable, Identifiable {
    /// Stable identity, so a single run can be deleted without matching on its text.
    ///
    /// Decoded leniently: runs written before this existed have no `id` field, and failing
    /// their whole line would throw away the user's history to add a delete button. Those
    /// get a fresh id on load, which is then persisted the next time the file is rewritten.
    var id: UUID = UUID()

    let date: Date
    let engine: String
    /// Language selection snapshotted for this recording. Optional so history written
    /// before multilingual dictation remains readable.
    let language: TranscriptionLanguageSelection?
    /// How long the key was held.
    let audioSeconds: Double
    /// Release → final text ready. This is the latency you actually feel.
    let processSeconds: Double
    var text: String
    /// Relative path to the captured CAF file in Murmure Data/Recordings, when audio was
    /// retained for this run. Optional so older history files continue to decode unchanged.
    var audioFile: String?
    /// Shared by every engine that processed the same recording, so the dashboard can
    /// present them as one side-by-side comparison instead of unrelated rows.
    var group: String?

    /// Dictionary corrections that fired on this transcript. Recorded so history can show
    /// whether the dictionary is actually doing anything, rather than leaving it to faith.
    ///
    /// Optional for backwards compatibility: runs recorded before the dictionary existed
    /// decode with this nil rather than failing the whole line.
    var corrections: [AppliedCorrection]?
    /// The user's latest edit, while retaining the first transcript they corrected.
    /// Optional so history created before correction learning remains decodable.
    var correction: TranscriptCorrectionRecord?

    var realtimeFactor: Double { audioSeconds / max(processSeconds, 0.0001) }
    var characters: Int { text.count }

    init(
        id: UUID = UUID(),
        date: Date,
        engine: String,
        language: TranscriptionLanguageSelection? = nil,
        audioSeconds: Double,
        processSeconds: Double,
        text: String,
        group: String? = nil,
        corrections: [AppliedCorrection]? = nil,
        audioFile: String? = nil,
        correction: TranscriptCorrectionRecord? = nil
    ) {
        self.id = id
        self.date = date
        self.engine = engine
        self.language = language
        self.audioSeconds = audioSeconds
        self.processSeconds = processSeconds
        self.text = text
        self.audioFile = audioFile
        self.group = group
        self.corrections = corrections
        self.correction = correction
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        engine = try container.decode(String.self, forKey: .engine)
        language = try container.decodeIfPresent(
            TranscriptionLanguageSelection.self,
            forKey: .language
        )
        audioSeconds = try container.decode(Double.self, forKey: .audioSeconds)
        processSeconds = try container.decode(Double.self, forKey: .processSeconds)
        text = try container.decode(String.self, forKey: .text)
        audioFile = try container.decodeIfPresent(String.self, forKey: .audioFile)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        corrections = try container.decodeIfPresent([AppliedCorrection].self, forKey: .corrections)
        correction = try container.decodeIfPresent(TranscriptCorrectionRecord.self, forKey: .correction)
    }

    func correcting(
        intendedText: String,
        inputMethod: TranscriptCorrectionRecord.InputMethod,
        rememberedRule: CorrectionRuleSuggestion?,
        pendingRule: CorrectionRuleSuggestion? = nil,
        at correctedAt: Date = Date()
    ) -> DictationRun {
        var updated = self
        updated.text = intendedText
        updated.correction = TranscriptCorrectionRecord(
            heardText: correction?.heardText ?? text,
            intendedText: intendedText,
            correctedAt: correctedAt,
            inputMethod: inputMethod,
            rememberedRule: rememberedRule,
            pendingRule: pendingRule
        )
        return updated
    }
}

/// Appends every dictation to a JSONL file and regenerates a dashboard beside it.
///
/// The dashboard is a plain file with a meta-refresh rather than a served page: `file://`
/// can't fetch its own data directory without tripping CORS, so instead of the page pulling
/// data, the app pushes a freshly rendered page after each run and the browser just reloads.
@MainActor
enum RunLog {
    private static var cachedRuns: [DictationRun] = []
    private static var hydrationStarted = false
    private static var hydrationTask: Task<Void, Never>?
    private static var pendingRuleRecoveryInFlight = false

    private static let persistenceWriter = SerializedPersistenceWriter()
    private static let dashboardWriter = SerializedPersistenceWriter()
    private static let correctionTransactions = CorrectionTransactionCoordinator()

    static var directory: URL { MurmureDataStore.rootURL }

    static var dashboardURL: URL { MurmureDataStore.dashboardURL }

    static func record(_ run: DictationRun) {
        cachedRuns.append(run)
        _ = enqueueAppend(run)
        regenerate()
        RunStore.shared.reload()
    }

    static func record(_ runs: [DictationRun]) {
        cachedRuns.append(contentsOf: runs)
        runs.forEach { _ = enqueueAppend($0) }
        regenerate()
        RunStore.shared.reload()
    }

    static func recordDurably(_ run: DictationRun) async -> Bool {
        let transaction = DurableRunAppendTransaction(
            persist: { enqueueAppend($0) },
            load: { cachedRuns },
            store: { runs in
                cachedRuns = runs
                regenerate()
                RunStore.shared.reload()
            }
        )
        return await transaction.record(run)
    }

    static func replaceDurably(id: UUID, with replacement: DictationRun) async -> Bool {
        await ensureHistoryHydrated()
        let transaction = DurableRunReplacementTransaction(
            persist: { enqueueRewrite($0) },
            load: { cachedRuns },
            store: { runs in
                cachedRuns = runs
                regenerate()
                RunStore.shared.reload()
            }
        )
        return await transaction.replace(id: id, with: replacement)
    }

    static func replaceDurably(
        expected: DictationRun,
        with replacement: DictationRun
    ) async -> Bool {
        await ensureHistoryHydrated()
        let transaction = DurableRunReplacementTransaction(
            persist: { enqueueRewrite($0) },
            load: { cachedRuns },
            store: { runs in
                cachedRuns = runs
                regenerate()
                RunStore.shared.reload()
            }
        )
        return await transaction.replace(expected: expected, with: replacement)
    }

    static func saveCorrection(
        id: UUID,
        intendedText: String,
        inputMethod: TranscriptCorrectionRecord.InputMethod,
        rememberedRule: CorrectionRuleSuggestion?
    ) async -> CorrectionSaveResult {
        let result: CorrectionSaveResult = await correctionTransactions.perform {
            guard await correct(
                id: id,
                intendedText: intendedText,
                inputMethod: inputMethod,
                rememberedRule: nil,
                pendingRule: rememberedRule
            ) else {
                return CorrectionSaveResult.historyFailed
            }
            guard let rememberedRule else { return CorrectionSaveResult.saved }
            guard await DictionaryStore.shared.remember(rememberedRule) else {
                return CorrectionSaveResult.rulePending
            }
            guard await correct(
                id: id,
                intendedText: intendedText,
                inputMethod: inputMethod,
                rememberedRule: rememberedRule
            ) else {
                return CorrectionSaveResult.rememberedMetadataPending
            }
            return CorrectionSaveResult.saved
        }
        // A previous launch recovery may have stopped on a transient drive failure, and this
        // transaction may itself have left a durable pending handoff. One bounded retry is safe
        // and idempotent; a still-unavailable drive waits for the next save or launch.
        beginDeferredPendingRuleRecovery()
        return result
    }

    @discardableResult
    private static func correct(
        id: UUID,
        intendedText: String,
        inputMethod: TranscriptCorrectionRecord.InputMethod,
        rememberedRule: CorrectionRuleSuggestion?,
        pendingRule: CorrectionRuleSuggestion? = nil
    ) async -> Bool {
        await ensureHistoryHydrated()
        guard let index = cachedRuns.firstIndex(where: { $0.id == id }) else { return false }
        let originalRuns = cachedRuns
        var correctedRuns = cachedRuns
        correctedRuns[index] = correctedRuns[index].correcting(
            intendedText: intendedText,
            inputMethod: inputMethod,
            rememberedRule: rememberedRule,
            pendingRule: pendingRule
        )
        cachedRuns = correctedRuns
        regenerate()
        RunStore.shared.reload()

        guard await enqueueRewrite(correctedRuns).value else {
            let rolledBack = RunLogCorrectionRollback.restore(
                attempted: correctedRuns[index],
                original: originalRuns[index],
                in: cachedRuns
            )
            if rolledBack != cachedRuns {
                cachedRuns = rolledBack
                regenerate()
                RunStore.shared.reload()
            }
            return false
        }
        return true
    }

    static func load() -> [DictationRun] {
        cachedRuns
    }

    /// Hydrates history without making SwiftUI wait for a removable-volume file open.
    static func beginDeferredHydration() {
        guard !hydrationStarted else { return }
        hydrationStarted = true
        hydrationTask = Task { @MainActor in
            let loaded = await Task.detached(priority: .utility) {
                readRunsFromDisk()
            }.value
            // A recording can finish before the drive responds. Preserve that in-memory
            // run and append the older disk history around it instead of replacing it.
            let knownIDs = Set(cachedRuns.map(\.id))
            cachedRuns.insert(contentsOf: loaded.filter { !knownIDs.contains($0.id) }, at: 0)
            regenerate()
            RunStore.shared.reload()
        }
    }

    private static func ensureHistoryHydrated() async {
        if !hydrationStarted { beginDeferredHydration() }
        await hydrationTask?.value
    }

    /// Retries only corrections that were durably written as pending before dictionary
    /// persistence began. A rule is never activated without either this journal entry or its
    /// final remembered snapshot in history.
    static func beginDeferredPendingRuleRecovery() {
        guard !pendingRuleRecoveryInFlight else { return }
        pendingRuleRecoveryInFlight = true
        Task { @MainActor in
            defer { pendingRuleRecoveryInFlight = false }
            await ensureHistoryHydrated()
            guard await DictionaryStore.shared.ensureHydrated() else {
                Log.app.error("pending correction rule recovery is waiting for dictionary hydration")
                return
            }
            await correctionTransactions.perform {
                await reconcilePendingRules()
            }
        }
    }

    private static func reconcilePendingRules() async {
        for pending in PendingCorrectionRuleRecovery.pendingRules(in: cachedRuns) {
            guard PendingCorrectionRuleRecovery.isCurrent(pending, in: cachedRuns) else { continue }
            guard await DictionaryStore.shared.remember(pending.rule) else {
                Log.app.error("pending correction rule is waiting for dictionary persistence")
                continue
            }
            guard PendingCorrectionRuleRecovery.isCurrent(pending, in: cachedRuns) else { continue }
            guard await correct(
                id: pending.runID,
                intendedText: pending.intendedText,
                inputMethod: pending.inputMethod,
                rememberedRule: pending.rule
            ) else {
                Log.app.error("pending correction rule is waiting for history metadata persistence")
                continue
            }
        }
    }

    private nonisolated static func readRunsFromDisk() -> [DictationRun] {
        guard let data = try? Data(contentsOf: MurmureDataStore.runsURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(DictationRun.self, from: Data(line))
        }
    }

    static func regenerate() {
        let runs = load()
        let compareMode = Settings.shared.compareMode
        let key = Settings.shared.pushToTalkBinding.label
        let url = dashboardURL
        _ = dashboardWriter.enqueue {
            let dashboard = DashboardHTML.render(runs: runs, compareMode: compareMode, key: key)
            do {
                try dashboard.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                Log.app.error("dashboard save failed: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Deletes one run.
    static func delete(_ run: DictationRun) {
        delete(ids: [run.id])
    }

    /// Deletes every run in a comparison group — the engines all transcribed one utterance,
    /// so removing that utterance means removing all of its rows.
    static func deleteGroup(_ group: String) {
        Task { @MainActor in
            await ensureHistoryHydrated()
            rewrite(load().filter { $0.group != group })
        }
    }

    static func delete(ids: Set<UUID>) {
        Task { @MainActor in
            await ensureHistoryHydrated()
            rewrite(load().filter { !ids.contains($0.id) })
        }
    }

    static func clear() {
        Task { @MainActor in
            await ensureHistoryHydrated()
            rewrite([])
        }
    }

    /// Replaces the whole file through the same serialized snapshot writer used by recording.
    /// This also persists ids assigned to older runs during hydration.
    private static func rewrite(_ runs: [DictationRun]) {
        cachedRuns = runs
        _ = enqueueRewrite(runs)
        regenerate()
        RunStore.shared.reload()
    }

    private static func enqueueAppend(_ run: DictationRun) -> Task<Bool, Never> {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            var encoded = try encoder.encode(run)
            encoded.append(0x0A)
            let line = encoded
            let url = MurmureDataStore.runsURL
            return persistenceWriter.enqueue {
                do {
                    if let handle = try? FileHandle(forWritingTo: url) {
                        defer { try? handle.close() }
                        _ = try handle.seekToEnd()
                        try handle.write(contentsOf: line)
                    } else {
                        try line.write(to: url)
                    }
                    return true
                } catch {
                    Log.app.error("history append failed: \(error.localizedDescription)")
                    return false
                }
            }
        } catch {
            Log.app.error("history append encoding failed: \(error.localizedDescription)")
            return Task { false }
        }
    }

    private static func enqueueRewrite(_ runs: [DictationRun]) -> Task<Bool, Never> {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let lines = try runs.map { run in
                let data = try encoder.encode(run)
                guard let line = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileWriteInapplicableStringEncoding)
                }
                return line
            }
            let snapshot = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            let url = MurmureDataStore.runsURL
            return persistenceWriter.enqueue {
                do {
                    try snapshot.write(to: url, atomically: true, encoding: .utf8)
                    return true
                } catch {
                    Log.app.error("history rewrite failed: \(error.localizedDescription)")
                    return false
                }
            }
        } catch {
            Log.app.error("history rewrite encoding failed: \(error.localizedDescription)")
            return Task { false }
        }
    }
}
