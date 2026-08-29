import MurmurDictionary
import Foundation
import Observation

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
    static let shared = DictionaryStore()

    private(set) var entries: [DictionaryEntry] = []

    /// Bumped whenever entries change, so the engine can rebuild its bias list lazily
    /// instead of on every transcription.
    private(set) var revision = 0

    private var watcher: DispatchSourceFileSystemObject?
    /// Set while we're writing, so our own save doesn't read back as an external edit.
    private var isSaving = false
    private var hydrationStarted = false

    static var fileURL: URL { MurmureDataStore.dictionaryURL }

    private init() {
        // The dictionary lives on the removable drive. Hydrate it after the first window is
        // visible so a sleeping volume can never hold SwiftUI's launch thread hostage.
    }

    /// Loads the external dictionary in the background and starts the file watcher once the
    /// initial snapshot is available.
    func beginDeferredHydration() {
        guard !hydrationStarted else { return }
        hydrationStarted = true
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            let text = try? String(contentsOf: url, encoding: .utf8)
            await MainActor.run {
                if let text { self.adopt(text) }
                self.startWatching()
            }
        }
    }

    // MARK: - Editing

    func add(_ entry: DictionaryEntry) {
        entries.append(entry)
        save()
    }

    func update(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func delete(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func delete(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func remember(_ suggestion: CorrectionRuleSuggestion) {
        entries = CorrectionLearner.upserting(suggestion, into: entries)
        save()
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
        guard let text = try? String(contentsOf: Self.fileURL, encoding: .utf8) else {
            entries = []
            revision += 1
            return
        }
        adopt(text)
    }

    private func adopt(_ text: String) {
        entries = Self.parse(text)
        revision += 1
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

    private func save() {
        revision += 1
        isSaving = true

        let body = entries.map(\.fileLine).joined(separator: "\n")
        let text = Self.header + body + "\n"
        let url = Self.fileURL
        let writeTask = Task.detached(priority: .utility) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        Task { @MainActor in
            _ = await writeTask.value
            self.isSaving = false
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
