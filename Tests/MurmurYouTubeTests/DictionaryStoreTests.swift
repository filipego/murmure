import Foundation
import MurmurDictionary
import Testing

@testable import MurmurYouTube

@Suite("Dictionary persistence")
struct DictionaryStoreTests {
    @Test("deferred hydration completes before a queued mutation snapshots entries")
    @MainActor
    func hydrationPrecedesMutation() async {
        let gate = HydrationGate()
        let writes = DictionaryWriteRecorder()
        let store = DictionaryStore(
            loadText: { .loaded(await gate.wait() ?? "") },
            persistText: { text in
                await writes.record(text)
                return true
            }
        )

        store.beginDeferredHydration()
        store.add(.term("New entry"))
        await gate.release("Old entry\n")

        await writes.waitForFirstWrite()

        #expect(store.entries.map(\.write) == ["Old entry", "New entry"])
        let persisted = await writes.latest
        #expect(persisted?.contains("Old entry") == true)
        #expect(persisted?.contains("New entry") == true)
    }

    @Test("failed hydration blocks mutations and never persists an empty replacement")
    @MainActor
    func failedHydrationPreservesSafety() async {
        let writes = DictionaryWriteRecorder()
        let store = DictionaryStore(
            loadText: { .failed },
            persistText: { text in
                await writes.record(text)
                return true
            }
        )

        store.beginDeferredHydration()
        #expect(await store.ensureHydrated() == false)
        #expect(await store.remember(CorrectionRuleSuggestion(hear: "old", write: "new")) == false)
        store.add(.term("New entry"))
        await Task.yield()

        #expect(store.entries.isEmpty)
        #expect(await writes.count == 0)
    }

    @Test("a transient hydration failure can be retried without losing existing entries")
    @MainActor
    func transientHydrationFailureCanRetry() async {
        let loads = DictionaryLoadSequence([
            .failed,
            .loaded("Old entry\n")
        ])
        let writes = DictionaryWriteRecorder()
        let store = DictionaryStore(
            loadText: { await loads.next() },
            persistText: { text in
                await writes.record(text)
                return true
            }
        )

        #expect(await store.ensureHydrated() == false)
        #expect(await store.ensureHydrated())
        #expect(await store.remember(CorrectionRuleSuggestion(hear: "old", write: "new")))

        let persisted = await writes.latest
        #expect(persisted?.contains("Old entry") == true)
        #expect(persisted?.contains("old -> new") == true)
    }
}

private actor DictionaryLoadSequence {
    private var results: [DictionaryHydrationResult]

    init(_ results: [DictionaryHydrationResult]) {
        self.results = results
    }

    func next() -> DictionaryHydrationResult {
        results.removeFirst()
    }
}

private actor HydrationGate {
    private var continuation: CheckedContinuation<String?, Never>?
    private var released = false
    private var releasedText: String?

    func wait() async -> String? {
        if released { return releasedText }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ text: String?) {
        released = true
        releasedText = text
        continuation?.resume(returning: text)
        continuation = nil
    }
}

private actor DictionaryWriteRecorder {
    private(set) var count = 0
    private(set) var latest: String?
    private var waiter: CheckedContinuation<Void, Never>?

    func record(_ text: String) {
        count += 1
        latest = text
        waiter?.resume()
        waiter = nil
    }

    func waitForFirstWrite() async {
        guard count == 0 else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
