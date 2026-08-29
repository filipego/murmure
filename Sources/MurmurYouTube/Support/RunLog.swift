import MurmurDictionary
import Foundation

/// One completed dictation.
struct DictationRun: Codable, Sendable, Identifiable {
    /// Stable identity, so a single run can be deleted without matching on its text.
    ///
    /// Decoded leniently: runs written before this existed have no `id` field, and failing
    /// their whole line would throw away the user's history to add a delete button. Those
    /// get a fresh id on load, which is then persisted the next time the file is rewritten.
    var id: UUID = UUID()

    let date: Date
    let engine: String
    /// How long the key was held.
    let audioSeconds: Double
    /// Release → final text ready. This is the latency you actually feel.
    let processSeconds: Double
    let text: String
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

    var realtimeFactor: Double { audioSeconds / max(processSeconds, 0.0001) }
    var characters: Int { text.count }

    init(
        id: UUID = UUID(),
        date: Date,
        engine: String,
        audioSeconds: Double,
        processSeconds: Double,
        text: String,
        group: String? = nil,
        corrections: [AppliedCorrection]? = nil,
        audioFile: String? = nil
    ) {
        self.id = id
        self.date = date
        self.engine = engine
        self.audioSeconds = audioSeconds
        self.processSeconds = processSeconds
        self.text = text
        self.audioFile = audioFile
        self.group = group
        self.corrections = corrections
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        engine = try container.decode(String.self, forKey: .engine)
        audioSeconds = try container.decode(Double.self, forKey: .audioSeconds)
        processSeconds = try container.decode(Double.self, forKey: .processSeconds)
        text = try container.decode(String.self, forKey: .text)
        audioFile = try container.decodeIfPresent(String.self, forKey: .audioFile)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        corrections = try container.decodeIfPresent([AppliedCorrection].self, forKey: .corrections)
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

    static var directory: URL { MurmureDataStore.rootURL }

    static var dashboardURL: URL { MurmureDataStore.dashboardURL }
    private static var runsURL: URL { MurmureDataStore.runsURL }

    static func record(_ run: DictationRun) {
        append(run)
        cachedRuns.append(run)
        regenerate()
        RunStore.shared.reload()
    }

    static func record(_ runs: [DictationRun]) {
        runs.forEach(append)
        cachedRuns.append(contentsOf: runs)
        regenerate()
        RunStore.shared.reload()
    }

    private static func append(_ run: DictationRun) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(run) else { return }
        line.append(0x0A) // newline
        let url = runsURL
        Task.detached(priority: .utility) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    static func load() -> [DictationRun] {
        cachedRuns
    }

    /// Hydrates history without making SwiftUI wait for a removable-volume file open.
    static func beginDeferredHydration() {
        guard !hydrationStarted else { return }
        hydrationStarted = true
        Task.detached(priority: .utility) {
            let loaded = readRunsFromDisk()
            await MainActor.run {
                // A recording can finish before the drive responds. Preserve that in-memory
                // run and append the older disk history around it instead of replacing it.
                let knownIDs = Set(cachedRuns.map(\.id))
                cachedRuns.insert(contentsOf: loaded.filter { !knownIDs.contains($0.id) }, at: 0)
                RunStore.shared.reload()
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
        let key = Settings.shared.pushToTalkKey.displayName
        let url = dashboardURL
        Task.detached(priority: .utility) {
            let dashboard = DashboardHTML.render(runs: runs, compareMode: compareMode, key: key)
            try? dashboard.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Deletes one run.
    static func delete(_ run: DictationRun) {
        delete(ids: [run.id])
    }

    /// Deletes every run in a comparison group — the engines all transcribed one utterance,
    /// so removing that utterance means removing all of its rows.
    static func deleteGroup(_ group: String) {
        rewrite(load().filter { $0.group != group })
    }

    static func delete(ids: Set<UUID>) {
        rewrite(load().filter { !ids.contains($0.id) })
    }

    static func clear() {
        cachedRuns.removeAll(keepingCapacity: false)
        let url = runsURL
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
        regenerate()
        RunStore.shared.reload()
    }

    /// Replaces the whole file. Deleting can't be an append, and rewriting also persists the
    /// ids that older runs were assigned on load.
    private static func rewrite(_ runs: [DictationRun]) {
        cachedRuns = runs
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let body = runs.compactMap { run -> String? in
            guard let data = try? encoder.encode(run) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")

        // Atomic: a partial write here would lose history that the user didn't ask to delete.
        let url = runsURL
        let persistedBody = body.isEmpty ? "" : body + "\n"
        Task.detached(priority: .utility) {
            try? persistedBody.write(to: url, atomically: true, encoding: .utf8)
        }

        regenerate()
        RunStore.shared.reload()
    }
}
