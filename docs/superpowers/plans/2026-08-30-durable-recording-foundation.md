# Durable Recording Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the remaining cloud comparison behavior and make every released recording and processed transcript durable enough to recover without automatic reinsertion.

**Architecture:** Keep `DictationController` as the main-actor orchestrator. Add a Foundation-only `MurmurSessionCore` target containing the persisted state machine and real-filesystem session store. Stage audio under local Application Support before final engine processing, persist processed text before insertion, promote staged audio and history idempotently, and never insert text from launch recovery.

**Tech Stack:** Swift 6.2, Swift Testing, XCTest, Swift Package Manager, AVFoundation, AppKit, SwiftUI, JSON manifests, CAF audio.

## Global Constraints

- macOS 26 remains the modern application floor.
- Normal and comparison dictation remain local. GitHub update checks and model downloads may use the network but may not contain private speech data.
- The existing visual presentation is locked. This phase may change comparison copy only where removing Wispr requires it.
- `shared/dictionary-test-vectors.json` remains unchanged.
- `MainActor.assumeIsolated` may be used only where execution is already proven to be on the main actor. Cross-actor work uses `await MainActor.run`.
- Audio capture order must remain deterministic.
- Recovery never inserts text automatically.
- Every production behavior begins with a failing test.
- Build and full test verification use `make`; no bare `swift build`.

---

## File map

### New files

- `Sources/MurmurSessionCore/RecordingSession.swift` owns persisted session values and legal state transitions.
- `Sources/MurmurSessionCore/RecordingSessionStore.swift` owns atomic manifest persistence, staged-audio locations, recovery enumeration, and idempotent completion.
- `Tests/MurmurSessionCoreTests/RecordingSessionTests.swift` proves state-machine and schema behavior.
- `Tests/MurmurSessionCoreTests/RecordingSessionStoreTests.swift` proves real-filesystem persistence and recovery behavior.
- `Sources/MurmurYouTube/Core/LocalComparisonPlan.swift` defines the only engines allowed in comparison mode.
- `Tests/MurmurYouTubeTests/LocalComparisonPlanTests.swift` prevents cloud participants from returning.
- `Sources/MurmurYouTube/Support/RecordingSessionCoordinator.swift` adapts captured buffers, `MurmureDataStore`, `RunLog`, and `MurmurSessionCore` for the application.
- `Tests/MurmurYouTubeTests/RecordingSessionCoordinatorTests.swift` proves promotion and recovery do not inject text.

### Modified files

- `Package.swift` adds `MurmurSessionCore` and its test target, then links it into `MurmurYouTube`.
- `Sources/MurmurYouTube/Core/EngineComparison.swift` creates engines from `LocalComparisonPlan`.
- `Sources/MurmurYouTube/Core/DictationController.swift` removes Wispr triggering and uses durable sessions.
- `Sources/MurmurYouTube/UI/ComparisonWindow.swift` describes Apple-versus-Parakeet comparison only.
- `Sources/MurmurYouTube/Support/RunLog.swift` adds a durable append result and concurrency-safe rollback policy.
- `Sources/MurmurYouTube/Support/MurmurDataStore.swift` promotes a verified staged CAF into final history storage.
- `Sources/MurmurYouTube/MurmurYouTubeApp.swift` starts idempotent session recovery after history hydration.
- `Tests/MurmurYouTubeTests/CorrectionHistoryTests.swift` covers durable append rollback while preserving concurrent history.

### Removed files

- `Sources/MurmurYouTube/Core/WisprTrigger.swift` is removed because it sends microphone audio to a third-party application.
- `Sources/MurmurYouTube/Transcription/WisprReader.swift` is removed because comparison mode is local-only.

## Throughput checkpoint

- **Blocking first steps.** Capture the current installed comparison and main-window baselines. Land the local comparison contract before deleting Wispr code. Land session types before the store and controller integration.
- **Independent workstreams.** Session domain tests and local comparison tests touch disjoint files. Current collaboration policy does not authorize subagents, so work remains serial in this task.
- **Shared mutable state.** `DictationController`, `RunLog`, and storage promotion share session identity. `RecordingSessionStore` owns manifests; `RunLog` owns history; the coordinator orders their writes instead of allowing either to reach into the other.
- **Smallest safe decomposition.** One implementer is safest because controller integration, history persistence, and promotion ordering share invariants. Each task still lands as a separately verified commit.

---

### Task 1: Capture the authoritative baseline

**Files:**

- Create: `.impeccable/review/local-first-baseline.md`
- Create: `.impeccable/review/local-first-baseline/` screenshots through the exact-surface workflow

**Interfaces:**

- Consumes: installed `/Applications/Murmure.app` version and current light/dark appearance.
- Produces: surface-ledger rows for main window, Settings, comparison window, and a history row with audio.

- [ ] **Step 1: Record artifact identity**

Run:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Murmure.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/Murmure.app/Contents/Info.plist
shasum -a 256 /Applications/Murmure.app/Contents/MacOS/MurmurYouTube
```

Expected: version `0.1.12`, build `12`, and one SHA-256 identity.

- [ ] **Step 2: Capture installed light-appearance surfaces**

Use `actual-surface-verifier` with Computer Use. Capture the main window, Settings, comparison window, and a representative history row without changing settings or data.

Expected: four current installed-surface images with paths recorded in the ledger.

- [ ] **Step 3: Capture installed dark-appearance surfaces**

Use an existing app/system dark appearance only if it can be selected without changing a protected global setting. If that requires a system-setting mutation, record dark appearance as pending rather than changing it without confirmation.

Expected: dark rows contain direct evidence or the exact unavailable proof.

- [ ] **Step 4: Write the baseline ledger**

The ledger must contain:

```markdown
| Surface | Artifact | Appearance/state | Evidence | Protected delta |
| --- | --- | --- | --- | --- |
| Main window | 0.1.12 (12), SHA-256 | Light, existing history | <absolute screenshot path> | Baseline |
| Settings | 0.1.12 (12), SHA-256 | Light | <absolute screenshot path> | Baseline |
| Engine comparison | 0.1.12 (12), SHA-256 | Light | <absolute screenshot path> | Baseline |
| History audio row | 0.1.12 (12), SHA-256 | Light | <absolute screenshot path> | Baseline |
```

- [ ] **Step 5: Commit**

```bash
git add .impeccable/review/local-first-baseline.md .impeccable/review/local-first-baseline
git commit -m "test: capture local-first app baseline"
```

---

### Task 2: Make comparison mode local-only

**Files:**

- Create: `Sources/MurmurYouTube/Core/LocalComparisonPlan.swift`
- Create: `Tests/MurmurYouTubeTests/LocalComparisonPlanTests.swift`
- Modify: `Sources/MurmurYouTube/Core/EngineComparison.swift`
- Modify: `Sources/MurmurYouTube/Core/DictationController.swift`
- Modify: `Sources/MurmurYouTube/UI/ComparisonWindow.swift`
- Remove: `Sources/MurmurYouTube/Core/WisprTrigger.swift`
- Remove: `Sources/MurmurYouTube/Transcription/WisprReader.swift`

**Interfaces:**

- Consumes: `TranscriptionEngine`, `AppleSpeechEngine`, and `ParakeetEngine`.
- Produces: `LocalComparisonParticipant.allCases` and `makeEngine()`.

- [ ] **Step 1: Write the failing participant test**

Create `LocalComparisonPlanTests.swift`:

```swift
import Testing
@testable import MurmurYouTube

@Suite("Local comparison plan")
struct LocalComparisonPlanTests {
    @Test("comparison contains only local engines")
    func containsOnlyLocalEngines() {
        #expect(LocalComparisonParticipant.allCases.map(\.displayName) == ["Apple", "Parakeet"])
    }
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter LocalComparisonPlanTests
```

Expected: compilation fails because `LocalComparisonParticipant` does not exist.

- [ ] **Step 3: Add the minimal participant registry**

Create `LocalComparisonPlan.swift`:

```swift
enum LocalComparisonParticipant: CaseIterable, Sendable {
    case apple
    case parakeet

    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .parakeet: "Parakeet"
        }
    }

    func makeEngine() -> any TranscriptionEngine {
        switch self {
        case .apple: AppleSpeechEngine()
        case .parakeet: ParakeetEngine()
        }
    }
}
```

Change `EngineComparison.run` to map `LocalComparisonParticipant.allCases` into `(displayName, makeEngine())` pairs.

- [ ] **Step 4: Verify GREEN**

Run the focused command from Step 2.

Expected: `LocalComparisonPlanTests` passes.

- [ ] **Step 5: Remove every runtime Wispr path**

Delete button-trigger calls to `WisprTrigger`, delete the Wispr polling block in `runComparison`, update comparison copy to Apple and Parakeet, and remove the two Wispr source files.

- [ ] **Step 6: Verify the privacy contract**

Run:

```bash
rg -n "WisprTrigger|WisprReader|Waiting for Wispr|Wispr Flow all hear" Sources Tests
```

Expected: no runtime references. Dictionary examples containing the literal product name may remain only in dictionary fixtures or explanatory examples.

- [ ] **Step 7: Run the full suite**

Run:

```bash
make test
```

Expected: all executed tests pass with no new warnings.

- [ ] **Step 8: Commit**

```bash
git add Sources/MurmurYouTube/Core/LocalComparisonPlan.swift Sources/MurmurYouTube/Core/EngineComparison.swift Sources/MurmurYouTube/Core/DictationController.swift Sources/MurmurYouTube/UI/ComparisonWindow.swift Tests/MurmurYouTubeTests/LocalComparisonPlanTests.swift
git add -u Sources/MurmurYouTube/Core/WisprTrigger.swift Sources/MurmurYouTube/Transcription/WisprReader.swift
git commit -m "refactor: keep engine comparison local"
```

---

### Task 3: Add the durable session domain

**Files:**

- Create: `Sources/MurmurSessionCore/RecordingSession.swift`
- Create: `Tests/MurmurSessionCoreTests/RecordingSessionTests.swift`
- Modify: `Package.swift`

**Interfaces:**

- Consumes: Foundation value types only.
- Produces: `RecordingSessionManifest`, `RecordingSessionStatus`, `RecordingFailure`, `RecordingTrigger`, `SessionEngineID`, `TranscriptionLanguageSelection`, and legal transition methods.

- [ ] **Step 1: Register empty targets**

Add a `MurmurSessionCore` target and `MurmurSessionCoreTests` test target in `Package.swift`. Add `MurmurSessionCore` to the `MurmurYouTube` executable dependencies.

- [ ] **Step 2: Write failing transition tests**

Create `RecordingSessionTests.swift` with these behaviors:

```swift
import Foundation
import Testing
@testable import MurmurSessionCore

@Suite("Recording session")
struct RecordingSessionTests {
    @Test("released audio advances through processing and durable final text")
    func legalProcessingPath() throws {
        var session = RecordingSessionManifest.sample()
        try session.release(at: Date(timeIntervalSince1970: 20), audioFile: "audio.caf")
        try session.transition(to: .processing)
        try session.transition(to: .processed(finalText: "Bonjour tout le monde."))
        try session.transition(to: .completed(runID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!))
        #expect(session.status.isCompleted)
    }

    @Test("a completed session cannot return to processing")
    func terminalCompletion() throws {
        var session = RecordingSessionManifest.sample()
        try session.release(at: Date(timeIntervalSince1970: 20), audioFile: "audio.caf")
        try session.transition(to: .processing)
        try session.transition(to: .processed(finalText: "Final"))
        try session.transition(to: .completed(runID: UUID()))
        #expect(throws: RecordingSessionTransitionError.self) {
            try session.transition(to: .processing)
        }
    }

    @Test("manifest survives a JSON round trip")
    func jsonRoundTrip() throws {
        var session = RecordingSessionManifest.sample()
        try session.release(at: Date(timeIntervalSince1970: 20), audioFile: "audio.caf")
        let data = try JSONEncoder.sessionEncoder.encode(session)
        let decoded = try JSONDecoder.sessionDecoder.decode(RecordingSessionManifest.self, from: data)
        #expect(decoded == session)
    }
}
```

Add a private test extension that constructs one deterministic sample manifest.

- [ ] **Step 3: Verify RED**

Run:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter RecordingSessionTests
```

Expected: compilation fails because the session domain does not exist.

- [ ] **Step 4: Implement the minimal state machine**

`RecordingSession.swift` must define public Codable, Sendable, Equatable values. Use these legal transitions:

```swift
private static func permits(_ current: RecordingSessionStatus, _ next: RecordingSessionStatus) -> Bool {
    switch (current, next) {
    case (.recording, .readyForTranscription),
         (.recording, .failed),
         (.recording, .cancelled),
         (.readyForTranscription, .processing),
         (.readyForTranscription, .failed),
         (.processing, .processed),
         (.processing, .failed),
         (.processed, .completed),
         (.processed, .failed),
         (.failed, .processing),
         (.failed, .cancelled):
        true
    default:
        false
    }
}
```

`release(at:audioFile:)` sets `releasedAt`, sets the relative staged filename, and performs the recording-to-ready transition. `JSONEncoder.sessionEncoder` and `JSONDecoder.sessionDecoder` use ISO-8601 dates.

- [ ] **Step 5: Verify GREEN**

Run the focused command from Step 3.

Expected: all `RecordingSessionTests` pass.

- [ ] **Step 6: Add failure and retry tests**

Add tests proving:

- a recording may fail with stage `.audioStaging`;
- a failed session may retry into `.processing`;
- cancelled and completed sessions are terminal;
- `.processed(finalText: "")` is rejected;
- `release` rejects an empty audio filename.

Run each new test first and confirm its expected failure before implementing the guard.

- [ ] **Step 7: Run full tests and commit**

```bash
make test
git add Package.swift Sources/MurmurSessionCore/RecordingSession.swift Tests/MurmurSessionCoreTests/RecordingSessionTests.swift
git commit -m "feat: add durable recording session domain"
```

Expected: full suite passes, then the commit contains only the session domain and package wiring.

---

### Task 4: Persist session manifests atomically

**Files:**

- Create: `Sources/MurmurSessionCore/RecordingSessionStore.swift`
- Create: `Tests/MurmurSessionCoreTests/RecordingSessionStoreTests.swift`

**Interfaces:**

- Consumes: `RecordingSessionManifest` and a caller-supplied local staging root.
- Produces: actor `RecordingSessionStore` with `create`, `load`, `transition`, `recoverableSessions`, `stagedAudioURL`, `markCompleted`, and `removeCompletedSession`.

- [ ] **Step 1: Write the failing real-filesystem tests**

Use a unique temporary directory per test. Cover:

```swift
@Test("create writes an atomic manifest that a new store can load")
func createAndReload() async throws

@Test("recoverable sessions exclude completed and cancelled manifests")
func recoveryFilter() async throws

@Test("repeating completion with the same run id is idempotent")
func completionIsIdempotent() async throws

@Test("completion with a different run id is rejected")
func conflictingCompletionIsRejected() async throws

@Test("a malformed manifest does not hide valid recoverable sessions")
func malformedManifestIsolation() async throws
```

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter RecordingSessionStoreTests
```

Expected: compilation fails because `RecordingSessionStore` does not exist.

- [ ] **Step 3: Implement the actor and file layout**

Use this layout:

```text
<staging-root>/
  <lowercase-session-uuid>/
    manifest.json
    audio.caf
```

The actor uses real filesystem operations. Every manifest rewrite uses `Data.write(options: .atomic)`. Directory enumeration catches malformed manifests individually and returns valid sessions in `startedAt` order.

- [ ] **Step 4: Verify GREEN**

Run the focused store tests.

Expected: all store tests pass.

- [ ] **Step 5: Add traversal and deletion safety tests**

Prove that store-generated URLs remain under the supplied root and `removeCompletedSession` refuses any non-completed manifest. Verify RED before adding each guard.

- [ ] **Step 6: Run full tests and commit**

```bash
make test
git add Sources/MurmurSessionCore/RecordingSessionStore.swift Tests/MurmurSessionCoreTests/RecordingSessionStoreTests.swift
git commit -m "feat: persist recoverable recording sessions"
```

---

### Task 5: Stage and promote audio with confirmation

**Files:**

- Modify: `Sources/MurmurYouTube/Support/MurmurDataStore.swift`
- Create: `Tests/MurmurYouTubeTests/AudioHistoryPromotionTests.swift`

**Interfaces:**

- Consumes: a completed staged CAF, session ID, and current Murmure data root.
- Produces: `AudioHistoryStore.promoteStagedAudio(from:id:) async -> AudioPromotionResult`.

- [ ] **Step 1: Write failing promotion tests**

Define the expected result:

```swift
enum AudioPromotionResult: Equatable, Sendable {
    case promoted(relativePath: String)
    case alreadyPromoted(relativePath: String)
    case failed(String)
}
```

Tests must prove:

- a staged CAF is copied to `Recordings/<id>.caf` and its bytes match;
- repeating promotion returns `.alreadyPromoted` when bytes match;
- an existing conflicting destination is not overwritten;
- a missing staged file returns `.failed`;
- the staged source remains after promotion until session completion is durable.

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter AudioHistoryPromotionTests
```

Expected: compilation fails because the promotion interface does not exist.

- [ ] **Step 3: Implement verified copy semantics**

Perform the copy in a detached utility task. Compare file size and SHA-256 after copying. Never replace an existing differing destination. Return only a relative path validated by `MurmureDataStore.relativePath(for:)`.

- [ ] **Step 4: Verify GREEN and full suite**

Run the focused tests, then `make test`.

Expected: all promotion and existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MurmurYouTube/Support/MurmurDataStore.swift Tests/MurmurYouTubeTests/AudioHistoryPromotionTests.swift
git commit -m "feat: confirm staged audio promotion"
```

---

### Task 6: Make history append durability observable

**Files:**

- Modify: `Sources/MurmurYouTube/Support/RunLog.swift`
- Modify: `Tests/MurmurYouTubeTests/CorrectionHistoryTests.swift`

**Interfaces:**

- Consumes: a completed `DictationRun`.
- Produces: `RunLog.recordDurably(_:) async -> Bool` and pure `RunLogAppendRollback.restore(attempted:in:)`.

- [ ] **Step 1: Write the failing rollback tests**

Add tests proving:

```swift
@Test("failed durable append removes only its attempted run")
func failedAppendRollbackPreservesConcurrentRuns()

@Test("rollback does nothing after the attempted run was superseded")
func rollbackDoesNotOverwriteNewerMutation()
```

- [ ] **Step 2: Verify RED**

Run the `CorrectionHistoryTests` filter.

Expected: compilation fails because `RunLogAppendRollback` does not exist.

- [ ] **Step 3: Implement the pure rollback**

The rollback removes the attempted run only when the current cache still contains that exact value at its ID. It preserves unrelated and newer mutations.

- [ ] **Step 4: Verify GREEN**

Run the focused correction-history suite.

Expected: new rollback tests pass.

- [ ] **Step 5: Add `recordDurably` test seams and implementation**

Append to the in-memory cache, refresh UI, await the serialized file append, and roll back only the attempted run if persistence fails. Do not change the existing fire-and-forget `record` behavior for comparison rows in this task.

- [ ] **Step 6: Run full tests and commit**

```bash
make test
git add Sources/MurmurYouTube/Support/RunLog.swift Tests/MurmurYouTubeTests/CorrectionHistoryTests.swift
git commit -m "feat: report durable history appends"
```

---

### Task 7: Coordinate staging, processing, promotion, and recovery

**Files:**

- Create: `Sources/MurmurYouTube/Support/RecordingSessionCoordinator.swift`
- Create: `Tests/MurmurYouTubeTests/RecordingSessionCoordinatorTests.swift`
- Modify: `Sources/MurmurYouTube/Core/DictationController.swift`
- Modify: `Sources/MurmurYouTube/MurmurYouTubeApp.swift`

**Interfaces:**

- Consumes: `RecordingSessionStore`, `AudioArchiveWriter`, `AudioHistoryStore`, and `RunLog` adapters.
- Produces: `RecordingSessionCoordinator.begin`, `stageReleasedAudio`, `persistProcessedText`, `completeLiveSession`, `fail`, and `recoverPendingSessions`.

- [ ] **Step 1: Name the application adapter shape in a failing test**

Use injected closures rather than test-only production methods:

```swift
struct RecordingSessionDependencies: Sendable {
    let writeAudio: @Sendable ([AudioChunk], URL) async throws -> Void
    let promoteAudio: @Sendable (URL, UUID) async -> AudioPromotionResult
    let appendHistory: @MainActor @Sendable (DictationRun) async -> Bool
}
```

Because `AudioChunk` belongs to the executable target, the coordinator remains in `MurmurYouTube`. Tests provide real temporary session storage and closure adapters.

- [ ] **Step 2: Write failing coordinator tests**

Cover:

- released audio is staged before status becomes ready;
- processed text is durable before the live completion closure is allowed to insert;
- promotion or history failure leaves a recoverable manifest;
- retrying completion with the same session/run IDs does not duplicate history;
- launch recovery promotes/history-completes processed sessions but never calls insertion;
- empty recognition becomes a recoverable `.transcription` failure with audio retained.

- [ ] **Step 3: Verify RED**

Run:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter RecordingSessionCoordinatorTests
```

Expected: compilation fails because the coordinator does not exist.

- [ ] **Step 4: Implement the minimal coordinator**

The coordinator owns ordering only. It does not capture audio, format text, apply dictionary corrections, or insert text. It advances manifests through:

```text
recording → readyForTranscription → processing → processed(finalText) → completed(runID)
```

On recovery, `.processed` sessions may promote audio and append history but may never call `TextInjector`.

- [ ] **Step 5: Verify GREEN**

Run the focused coordinator suite.

Expected: all coordinator tests pass.

- [ ] **Step 6: Integrate the controller test-first**

Add controller tests with injected coordinator/fake engine proving:

- release stages audio before final insertion;
- successful live completion inserts exactly once;
- staging failure presents an error and retains the manifest;
- controller cancellation marks the session cancelled;
- compare mode remains non-inserting and uses its existing grouped history flow.

Watch each test fail before changing `DictationController`.

- [ ] **Step 7: Start launch recovery**

After `RunLog.beginDeferredHydration()`, start one bounded recovery task. Recovery is idempotent and never blocks the first window.

- [ ] **Step 8: Run focused and full tests**

Run the coordinator/controller filters, then:

```bash
make test
```

Expected: every executed test passes and the prior dictionary vectors remain green.

- [ ] **Step 9: Commit**

```bash
git add Sources/MurmurYouTube/Support/RecordingSessionCoordinator.swift Sources/MurmurYouTube/Core/DictationController.swift Sources/MurmurYouTube/MurmurYouTubeApp.swift Tests/MurmurYouTubeTests/RecordingSessionCoordinatorTests.swift
git commit -m "feat: recover durable dictation sessions"
```

---

### Task 8: Verify the bundled and installed foundation

**Files:**

- Modify: `.impeccable/review/local-first-baseline.md`
- Create: `.impeccable/review/local-first-foundation/` evidence

**Interfaces:**

- Consumes: built, staged, and installed modern app.
- Produces: exact-surface proof and an updated acceptance ledger.

- [ ] **Step 1: Run clean static verification**

Run:

```bash
make test
make app
```

Expected: both commands exit 0. Record executed test counts and any intentional skips.

- [ ] **Step 2: Inspect the bundle**

Run:

```bash
file "$HOME/Library/Caches/MurmurYouTubeBuild/Murmure.app/Contents/MacOS/MurmurYouTube"
codesign --verify --deep --strict --verbose=2 "$HOME/Library/Caches/MurmurYouTubeBuild/Murmure.app"
```

Expected: architecture and signature result are recorded without overstating public trust.

- [ ] **Step 3: Install using the project workflow**

Run `make install`. This replaces only `/Applications/Murmure.app`, which the user explicitly authorized as the app under development.

Expected: installed version launches and existing dictionary/history/settings remain present.

- [ ] **Step 4: Exercise normal dictation**

Using TextEdit or another disposable local text field:

- dictate one short phrase;
- confirm exactly one insertion;
- confirm one history row and playable/revealable audio;
- confirm dictionary correction behavior remains unchanged.

- [ ] **Step 5: Exercise recoverable failure**

Use a controlled test hook or fixture that fails after staged audio and before completion. Relaunch the installed app.

Expected: audio remains under the local session store, recovery does not paste anything, and the session remains observable for the next history-retry phase.

- [ ] **Step 6: Exercise local comparison**

Run one Apple-versus-Parakeet comparison.

Expected: only Apple and Parakeet rows appear; no Wispr process is triggered or polled; nothing is inserted.

- [ ] **Step 7: Compare protected surfaces**

Capture the same main, Settings, comparison, and history states as Task 1. Populate:

```markdown
| Surface | Baseline | Result | Visible delta |
| --- | --- | --- | --- |
| Main window | <baseline> | <result> | None |
| Settings | <baseline> | <result> | None |
| Engine comparison | <baseline> | <result> | Copy only: Apple and Parakeet |
| History audio row | <baseline> | <result> | None |
```

Any unapproved delta is restored before proceeding.

- [ ] **Step 8: Run privacy inspection**

Search source and inspect runtime logs during normal and comparison dictation. Confirm that only update/model retrieval paths can use the network and no private content is attached.

- [ ] **Step 9: Commit evidence**

```bash
git add .impeccable/review/local-first-baseline.md .impeccable/review/local-first-foundation
git commit -m "test: verify durable local dictation foundation"
```

## Phase completion gate

Do not begin history playback/retranscription until all of these are true:

- local comparison contract and privacy inspection pass;
- all released audio is staged locally before completion side effects;
- final text is durable before live insertion;
- recovery never inserts text;
- repeated recovery cannot duplicate history;
- full tests pass;
- bundled and installed proof passes;
- protected surfaces are unchanged except approved comparison copy;
- commits are small, ordered, and contain no unrelated `docs/research` artifact.
