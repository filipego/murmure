import Foundation
import Observation

enum SnippetHydrationResult: Sendable {
    case loaded([SnippetEntry])
    case missing
    case failed
}

private func loadSnippetsFromDisk() async -> SnippetHydrationResult {
    await Task.detached(priority: .utility) {
        do {
            let data = try Data(contentsOf: MurmureDataStore.snippetsURL)
            return .loaded(try JSONDecoder().decode([SnippetEntry].self, from: data))
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return .missing
        } catch {
            Log.app.error("snippet load failed: \(error.localizedDescription)")
            return .failed
        }
    }.value
}

private func persistSnippetsToDisk(_ entries: [SnippetEntry]) async -> Bool {
    do {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: MurmureDataStore.snippetsURL, options: .atomic)
        return true
    } catch {
        Log.app.error("snippet save failed: \(error.localizedDescription)")
        return false
    }
}

@MainActor
@Observable
final class SnippetStore {
    static let shared = SnippetStore(
        loadEntries: loadSnippetsFromDisk,
        persistEntries: persistSnippetsToDisk
    )

    private(set) var entries: [SnippetEntry] = []
    private(set) var revision = 0

    private let loadEntries: @Sendable () async -> SnippetHydrationResult
    private let persistEntries: @Sendable ([SnippetEntry]) async -> Bool
    private let persistenceWriter = SerializedPersistenceWriter()
    private var hydrationStarted = false
    private var hydrationTask: Task<SnippetHydrationResult, Never>?
    private var hydrationAttemptID: UUID?
    private var mutationGeneration = 0

    init(
        loadEntries: @escaping @Sendable () async -> SnippetHydrationResult,
        persistEntries: @escaping @Sendable ([SnippetEntry]) async -> Bool
    ) {
        self.loadEntries = loadEntries
        self.persistEntries = persistEntries
    }

    func beginDeferredHydration() {
        guard !hydrationStarted else { return }
        hydrationStarted = true
        hydrationAttemptID = UUID()
        hydrationTask = Task { @MainActor in
            let result = await loadEntries()
            switch result {
            case .loaded(let loaded): adopt(loaded)
            case .missing: adopt([])
            case .failed: break
            }
            return result
        }
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

    func upsert(_ entry: SnippetEntry) async -> SnippetValidationIssue? {
        guard await ensureHydrated() else { return .persistenceFailed }
        if let issue = SnippetValidator.validate(
            trigger: entry.trigger,
            replacement: entry.replacement,
            entries: entries,
            excludingID: entry.id
        ) {
            return issue
        }

        let previous = entries
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        return await persistOrRollBack(previous: previous) ? nil : .persistenceFailed
    }

    func setEnabled(_ enabled: Bool, id: UUID) async -> Bool {
        guard await ensureHydrated(),
              let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let previous = entries
        entries[index].isEnabled = enabled
        return await persistOrRollBack(previous: previous)
    }

    func delete(id: UUID) async -> Bool {
        guard await ensureHydrated(), entries.contains(where: { $0.id == id }) else {
            return false
        }
        let previous = entries
        entries.removeAll { $0.id == id }
        return await persistOrRollBack(previous: previous)
    }

    var expander: SnippetExpander { SnippetExpander(entries: entries) }

    private func adopt(_ loaded: [SnippetEntry]) {
        entries = loaded
        revision += 1
        mutationGeneration += 1
    }

    private func persistOrRollBack(previous: [SnippetEntry]) async -> Bool {
        revision += 1
        mutationGeneration += 1
        let generation = mutationGeneration
        let snapshot = entries
        let persistEntries = persistEntries
        let result = await persistenceWriter.enqueue {
            await persistEntries(snapshot)
        }.value
        if !result, mutationGeneration == generation, entries == snapshot {
            entries = previous
            revision += 1
            mutationGeneration += 1
        }
        return result
    }
}
