import Foundation
import Testing
@testable import MurmurYouTube

@Suite("Snippet persistence")
struct SnippetStoreTests {
    @Test("Foundation's missing-file read error is recognized")
    func missingFileError() {
        let error = CocoaError(.fileReadNoSuchFile)
        #expect(isMissingLocalFile(error))
    }

    @Test("hydration completes before a mutation is persisted")
    @MainActor
    func hydrationBeforeMutation() async {
        let old = SnippetEntry(trigger: "old", replacement: "Old value")
        let gate = SnippetHydrationGate()
        let writes = SnippetWriteRecorder()
        let store = SnippetStore(
            loadEntries: { .loaded(await gate.wait()) },
            persistEntries: { entries in await writes.record(entries); return true }
        )

        store.beginDeferredHydration()
        async let saved = store.upsert(SnippetEntry(trigger: "new", replacement: "New value"))
        await gate.release([old])

        #expect(await saved == nil)
        #expect(store.entries.map(\.trigger) == ["old", "new"])
        #expect(await writes.latest?.map(\.trigger) == ["old", "new"])
    }

    @Test("expansion waits for deferred hydration")
    @MainActor
    func hydrationBeforeExpansion() async {
        let snippet = SnippetEntry(trigger: "contact card", replacement: "Private replacement")
        let gate = SnippetHydrationGate()
        let store = SnippetStore(
            loadEntries: { .loaded(await gate.wait()) },
            persistEntries: { _ in true }
        )

        store.beginDeferredHydration()
        async let expansion = store.expand("contact card")
        await gate.release([snippet])

        #expect(await expansion.applied?.id == snippet.id)
    }

    @Test("a failed write rolls back only the attempted mutation")
    @MainActor
    func failedWriteRollsBack() async {
        let old = SnippetEntry(trigger: "old", replacement: "Old value")
        let store = SnippetStore(
            loadEntries: { .loaded([old]) },
            persistEntries: { _ in false }
        )

        let issue = await store.upsert(SnippetEntry(trigger: "new", replacement: "New value"))

        #expect(issue == .persistenceFailed)
        #expect(store.entries == [old])
    }

    @Test("empty input is rejected even when storage hydration is unavailable")
    @MainActor
    func validationPrecedesHydration() async {
        let store = SnippetStore(
            loadEntries: { .failed },
            persistEntries: { _ in true }
        )

        let issue = await store.upsert(SnippetEntry(trigger: "", replacement: ""))

        #expect(issue == .emptyTrigger)
    }

    @Test("editing preserves identity and duplicate triggers are rejected")
    @MainActor
    func editingAndValidation() async {
        let first = SnippetEntry(trigger: "first", replacement: "One")
        let second = SnippetEntry(trigger: "second", replacement: "Two")
        let store = SnippetStore(
            loadEntries: { .loaded([first, second]) },
            persistEntries: { _ in true }
        )
        #expect(await store.ensureHydrated())

        let duplicate = SnippetEntry(id: second.id, trigger: "FIRST", replacement: "Changed")
        #expect(await store.upsert(duplicate) == .duplicateTrigger)

        let edited = SnippetEntry(id: second.id, trigger: "updated", replacement: "Changed")
        #expect(await store.upsert(edited) == nil)
        #expect(store.entries[1] == edited)
    }

    @Test("delete and enable changes persist ordered snapshots")
    @MainActor
    func deleteAndToggle() async {
        let first = SnippetEntry(trigger: "first", replacement: "One")
        let second = SnippetEntry(trigger: "second", replacement: "Two")
        let writes = SnippetWriteRecorder()
        let store = SnippetStore(
            loadEntries: { .loaded([first, second]) },
            persistEntries: { entries in await writes.record(entries); return true }
        )
        #expect(await store.ensureHydrated())

        #expect(await store.setEnabled(false, id: first.id))
        #expect(await store.delete(id: second.id))

        #expect(store.entries.count == 1)
        #expect(store.entries[0].isEnabled == false)
        #expect(await writes.latest == store.entries)
    }
}

private actor SnippetHydrationGate {
    private var continuation: CheckedContinuation<[SnippetEntry], Never>?
    private var value: [SnippetEntry]?

    func wait() async -> [SnippetEntry] {
        if let value { return value }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ entries: [SnippetEntry]) {
        value = entries
        continuation?.resume(returning: entries)
        continuation = nil
    }
}

private actor SnippetWriteRecorder {
    private(set) var latest: [SnippetEntry]?

    func record(_ entries: [SnippetEntry]) {
        latest = entries
    }
}
