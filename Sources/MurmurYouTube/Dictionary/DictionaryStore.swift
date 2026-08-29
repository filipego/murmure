import MurmurDictionary
import Foundation
import Observation

enum DictionaryHydrationResult: Sendable {
    case loaded(String)
    case missing
    case failed
}

private func loadDictionaryFromDisk() async -> DictionaryHydrationResult {
    let url = MurmureDataStore.dictionaryURL
    return await Task.detached(priority: .utility) {
        do {
            return .loaded(try String(contentsOf: url, encoding: .utf8))
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return .missing
        } catch {
            return .failed
        }
    }.value
}

private func persistDictionaryToDisk(_ text: String) async -> Bool {
    do {
        try text.write(to: MurmureDataStore.dictionaryURL, atomically: true, encoding: .utf8)
        return true
    } catch {
        Log.app.error("dictionary save failed: \(error.localizedDescription)")
        return false
    }
}

/// The dictionary, persisted as a plain text file you can edit by hand.
///
/// A text file rather than JSON, because the spec asks for something editable outside the UI
/// and JSON is only nominally that — quoting, escaping and a trailing-comma trap for anyone
/// adding a line in a hurry. The format is one entry per line:
///
/// ```
/// Anthropic
/// Vercel
/// cloud code -> Claude Code
/// # off: whisper flow -> Wispr Flow
/// ```
///
/// A bare line is a term. `X -> Y` is a correction. `#` starts a comment, and a disabled
/// entry is written as a `# off:` comment so it survives a round trip through the file
/// without silently disappearing.
///
/// The file is watched, so editing it in a text editor updates the UI live and vice versa.
@MainActor
@Observable
final class DictionaryStore {
    static let shared = DictionaryStore(
        loadText: loadDictionaryFromDisk,
        persistText: persistDictionaryToDisk,
        watchExternalFile: true
    )

    private(set) var entries: [DictionaryEntry] = []

    /// Bumped whenever entries change, so the engine can rebuild its bias list lazily
    /// instead of on every transcription.
    private(set) var revision = 0

    private var watcher: DispatchSourceFileSystemObject?
    /// Set while we're writing, so our own save doesn't read back as an external edit.
    private var isSaving = false
    private var pendingSaves = 0
    private var mutationGeneration = 0
    private var hydrationStarted = false
    private var hydrationTask: Task<DictionaryHydrationResult, Never>?
    private var hydrationAttemptID: UUID?

    private let persistenceWriter = SerializedPersistenceWriter()
    private let loadText: @Sendable () async -> DictionaryHydrationResult
    private let persistText: @Sendable (String) async -> Bool
    private let watchExternalFile: Bool

    static var fileURL: URL { MurmureDataStore.dictionaryURL }

    init(
        loadText: @escaping @Sendable () async -> DictionaryHydrationResult,
        persistText: @escaping @Sendable (String) async -> Bool,
        watchExternalFile: Bool = false
    ) {
        self.loadText = loadText
        self.persistText = persistText
        self.watchExternalFile = watchExternalFile
        // The dictionary lives on the removable drive. Hydrate it after the first window is
        // visible so a sleeping volume can never hold SwiftUI's launch thread hostage.
    }

    /// Loads the external dictionary in the background and starts the file watcher once the
    /// initial snapshot is available.
    func beginDeferredHydration() {
        guard !hydrationStarted else { return }
        hydrationStarted = true
        hydrationAttemptID = UUID()
        hydrationTask = Task { @MainActor in
            let result = await loadText()
            if case .loaded(let text) = result { self.adopt(text) }
            if self.watchExternalFile { self.startWatching() }
            return result
        }
    }

    // MARK: - Editing

    func add(_ entry: DictionaryEntry) {
        Task { @MainActor in
            guard await ensureHydrated() else {
                Log.app.error("dictionary add skipped because hydration failed")
                return
            }
            entries.append(entry)
            save()
        }
    }

    func update(_ entry: DictionaryEntry) {
        Task { @MainActor in
            guard await ensureHydrated() else {
                Log.app.error("dictionary update skipped because hydration failed")
                return
            }
            guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
            entries[index] = entry
            save()
        }
    }

    func delete(_ entry: DictionaryEntry) {
        Task { @MainActor in
            guard await ensureHydrated() else {
                Log.app.error("dictionary delete skipped because hydration failed")
                return
            }
            entries.removeAll { $0.id == entry.id }
            save()
        }
    }

    func delete(ids: Set<UUID>) {
        Task { @MainActor in
            guard await ensureHydrated() else {
                Log.app.error("dictionary delete skipped because hydration failed")
                return
            }
            entries.removeAll { ids.contains($0.id) }
            save()
        }
    }

    func remember(_ suggestion: CorrectionRuleSuggestion) async -> Bool {
        guard await ensureHydrated() else {
            Log.app.error("dictionary remember skipped because hydration failed")
            return false
        }
        let previous = entries
        entries = CorrectionLearner.upserting(suggestion, into: entries)
        let snapshot = entries
        let generation = mutationGeneration + 1
        let result = await save().value
        if !result, mutationGeneration == generation, entries == snapshot {
            entries = previous
            revision += 1
            mutationGeneration += 1
        }
        return result
    }

    @discardableResult
    func ensureHydrated() async -> Bool {
        if !hydrationStarted { beginDeferredHydration() }
        let attemptID = hydrationAttemptID
        guard let task = hydrationTask else { return true }
        let result = await task.value
        if case .failed = result {
            if hydrationAttemptID == attemptID {
                hydrationTask = nil
                hydrationAttemptID = nil
                hydrationStarted = false
            }
            return false
        }
        return true
    }

    /// Case- and diacritic-insensitive search across both sides of an entry.
    func filtered(by query: String) -> [DictionaryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            $0.write.localizedStandardContains(trimmed) || $0.hear.localizedStandardContains(trimmed)
        }
    }

    /// A corrector over the current entries. Rebuilt on demand — compiling a few dozen small
    /// regexes is cheap next to transcription, and caching it invites staleness.
    var corrector: DictionaryCorrector { DictionaryCorrector(entries: entries) }

    var biasPhrases: [String] { DictionaryCorrector.biasPhrases(from: entries) }

    // MARK: - Persistence

    private func load() {
        do {
            let text = try String(contentsOf: Self.fileURL, encoding: .utf8)
            adopt(text)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            entries = []
            revision += 1
            mutationGeneration += 1
        } catch {
            Log.app.error("dictionary reload failed: \(error.localizedDescription)")
        }
    }

    private func adopt(_ text: String) {
        entries = Self.parse(text)
        revision += 1
        mutationGeneration += 1
    }

    static func parse(_ text: String) -> [DictionaryEntry] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }

            // `# off:` is a disabled entry; any other comment is just a comment.
            var isEnabled = true
            if line.hasPrefix("#") {
                let stripped = line.dropFirst().trimmingCharacters(in: .whitespaces)
                guard stripped.lowercased().hasPrefix("off:") else { return nil }
                line = stripped.dropFirst(4).trimmingCharacters(in: .whitespaces)
                isEnabled = false
                guard !line.isEmpty else { return nil }
            }

            if let arrow = line.range(of: "->") {
                let hear = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let write = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !hear.isEmpty, !write.isEmpty else { return nil }
                return DictionaryEntry(kind: .correction, write: write, hear: hear, isEnabled: isEnabled)
            }

            return DictionaryEntry(kind: .term, write: line, isEnabled: isEnabled)
        }
    }

    @discardableResult
    private func save() -> Task<Bool, Never> {
        revision += 1
        mutationGeneration += 1

        let body = entries.map(\.fileLine).joined(separator: "\n")
        let text = Self.header + body + "\n"
        let persistText = self.persistText
        pendingSaves += 1
        isSaving = true
        let writeTask = persistenceWriter.enqueue {
            await persistText(text)
        }
        return Task { @MainActor in
            let result = await writeTask.value
            self.pendingSaves -= 1
            self.isSaving = self.pendingSaves > 0
            if result, self.watchExternalFile, self.watcher == nil {
                self.startWatching()
            }
            return result
        }
    }

    private static let header = """
        # Murmure dictionary
        #
        #   Anthropic                 a term — the engine is told this word exists
        #   cloud code -> Claude Code a correction — when you hear X, write Y
        #   # off: some rule -> Rule  a disabled entry
        #
        # Edit this file directly if you like; the app picks up changes immediately.

        """

    // MARK: - External edits

    /// Watches the file so a hand edit shows up in the UI without a relaunch.
    ///
    /// Rearms after every event: an atomic write replaces the inode, so the descriptor we
    /// were watching is gone the moment the file changes — including when *we* save.
    private func startWatching() {
        watcher?.cancel()
        let url = Self.fileURL

        Task.detached(priority: .utility) {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            await MainActor.run { self.installWatcher(descriptor) }
        }
    }

    private func installWatcher(_ descriptor: Int32) {

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.isSaving { self.load() }
            self.startWatching()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()

        watcher = source
    }
}
