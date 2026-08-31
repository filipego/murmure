# History Recovery and Retranscription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make saved and failed local recordings playable and locally retranscribable, with an explicit preview and confirmation before history changes and no text injection.

**Architecture:** Add one deep `RetranscriptionCoordinator` interface that accepts either a saved history run or a durable failed session. It delegates CAF decoding and engine replay to focused adapters, returns an immutable preview, and commits through durable history/session operations only after confirmation. SwiftUI owns presentation state; it never calls an engine, rewrites JSONL, or injects text directly.

**Tech Stack:** Swift 6.2, Swift Testing, Swift Package Manager, AVFoundation, Observation, SwiftUI, JSONL history, durable recording manifests.

## Global Constraints

- macOS 26 remains the modern application floor.
- Apple and Parakeet are the only transcription engines; both run locally.
- Retranscription never calls `TextInjector` and never changes the clipboard.
- A candidate transcript is not durable until the user explicitly confirms it.
- Confirmation replaces one existing history item by stable UUID or promotes one failed session into one history item; it never appends a duplicate.
- The original heard text and original audio path remain available after replacing an existing history item.
- Cancelling or closing the preview changes neither history nor the failed manifest.
- Existing `shared/dictionary-test-vectors.json` behavior remains unchanged.
- The protected shell, layout, colors, typography, spacing, and animation remain unchanged. Approved visible changes are one playback action, one retry action, a recoverable-recordings section when needed, and one existing-token preview sheet.
- Every production behavior begins with a failing test.
- Use `make` for the full suite and app build; never use bare `swift build`.
- Work is inline on `main` with the user's explicit consent; do not create a worktree.

---

## File map

### New files

- `Sources/MurmurAudioCore/AudioArchiveReader.swift` reads a CAF in bounded chunks and converts it to an engine-requested format.
- `Tests/MurmurAudioCoreTests/AudioArchiveReaderTests.swift` proves format conversion, ordering, duration, empty-file errors, and missing-file errors with real CAF fixtures.
- `Sources/MurmurYouTube/Transcription/ArchivedAudioTranscriber.swift` runs one `TranscriptionEngine` against archived audio and returns its final raw transcript and elapsed processing time.
- `Tests/MurmurYouTubeTests/ArchivedAudioTranscriberTests.swift` proves ordered feed, final-result collection, failure propagation, and engine finalization.
- `Sources/MurmurYouTube/History/RetranscriptionCoordinator.swift` owns preview creation and confirmed commit for history and failed-session sources.
- `Sources/MurmurYouTube/History/RecoverableRecordingStore.swift` exposes durable failed/ready/processing manifests to SwiftUI without making views read files.
- `Sources/MurmurYouTube/History/HistoryAudioPlayer.swift` owns single-recording play/stop state behind a tiny playback adapter seam.
- `Sources/MurmurYouTube/UI/RetranscriptionSheet.swift` renders engine choice, progress, candidate preview, failure, cancel, and confirm actions using existing design tokens.
- `Tests/MurmurYouTubeTests/RetranscriptionCoordinatorTests.swift` proves preview purity, no-injection behavior, confirmed replacement/promotion, cancellation, stale-preview rejection, and failures.
- `Tests/MurmurYouTubeTests/HistoryAudioPlayerTests.swift` proves single-source playback state and stop behavior through an injected adapter.

### Modified files

- `Sources/MurmurYouTube/Support/RunLog.swift` adds durable stable-ID history replacement with concurrency-safe rollback.
- `Tests/MurmurYouTubeTests/CorrectionHistoryTests.swift` proves replacement success, failure rollback, and preservation of unrelated concurrent runs.
- `Sources/MurmurYouTube/Support/RecordingSessionCoordinator.swift` exposes non-inserting completion and typed recoverable-session snapshots.
- `Sources/MurmurYouTube/MurmurYouTubeApp.swift` refreshes the recoverable catalog after launch reconciliation.
- `Sources/MurmurYouTube/UI/MainWindow.swift` replaces Finder reveal with play/stop, adds retry, displays recoverable recordings, and opens the preview sheet.
- `Sources/MurmurYouTube/UI/DesignSystem.swift` adds only missing semantic size tokens required by the approved sheet or recovery row; no token values already used by the protected shell change.

## Interface contract

```swift
struct ArchivedTranscription: Equatable, Sendable {
    let text: String
    let processSeconds: Double
}

enum RetranscriptionSource: Equatable, Sendable, Identifiable {
    case history(DictationRun)
    case recoverable(RecoverableRecording)
}

struct RetranscriptionPreview: Equatable, Sendable, Identifiable {
    let id: UUID
    let source: RetranscriptionSource
    let engine: SpeechEngineChoice
    let rawText: String
    let candidateText: String
    let processSeconds: Double
    let corrections: [AppliedCorrection]
}

@MainActor
protocol RetranscriptionCoordinating {
    func preview(source: RetranscriptionSource, engine: SpeechEngineChoice) async throws -> RetranscriptionPreview
    func confirm(_ preview: RetranscriptionPreview) async -> Bool
}
```

The coordinator's public interface is deliberately two operations. CAF decoding, engine lifecycle, cleanup, dictionary application, session transitions, and JSONL persistence remain implementation details.

---

### Task 1: Read archived CAF audio in engine format

**Files:**
- Create: `Sources/MurmurAudioCore/AudioArchiveReader.swift`
- Create: `Tests/MurmurAudioCoreTests/AudioArchiveReaderTests.swift`

**Interfaces:**
- Consumes: CAF URL, requested `AVAudioFormat`, optional bounded chunk size.
- Produces: `AudioArchiveReader.read(from:convertingTo:framesPerChunk:) throws -> [AVAudioPCMBuffer]`.

- [ ] **Step 1: Write the failing real-file tests**

Create a deterministic 16 kHz mono Int16 ramp, archive it with `AudioArchiveWriter`, then assert that reading as 16 kHz mono Float32 returns non-empty ordered chunks, the same total frame count, and normalized first/last sample values. Add tests that a zero-frame CAF throws `.noAudio` and a missing URL throws.

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter AudioArchiveReaderTests
```

Expected: compilation fails because `AudioArchiveReader` does not exist.

- [ ] **Step 3: Implement bounded reading and conversion**

Open `AVAudioFile(forReading:)`, allocate at most `framesPerChunk` in the file processing format, read until EOF, convert each non-empty buffer with `AVAudioConverter`, and throw `AudioArchiveError.noAudio` when no frames were produced. Never allocate the whole recording as one buffer.

- [ ] **Step 4: Verify GREEN and regressions**

Run the focused command, then:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter MurmurAudioCoreTests
```

Expected: all audio-core tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MurmurAudioCore/AudioArchiveReader.swift Tests/MurmurAudioCoreTests/AudioArchiveReaderTests.swift
git commit -m "feat: read archived dictation audio"
```

---

### Task 2: Replay archived audio through one local engine

**Files:**
- Create: `Sources/MurmurYouTube/Transcription/ArchivedAudioTranscriber.swift`
- Create: `Tests/MurmurYouTubeTests/ArchivedAudioTranscriberTests.swift`

**Interfaces:**
- Consumes: audio URL and `any TranscriptionEngine`.
- Produces: `ArchivedAudioTranscriber.transcribe(url:engine:) async throws -> ArchivedTranscription`.

- [ ] **Step 1: Write failing lifecycle tests**

Use a recording engine actor that requests a known format, records fed sample markers, and emits revised then final text. Assert the transcriber feeds every decoded chunk in order, drains the result stream before `finish()`, returns the latest trimmed text, records non-negative processing time, and calls `finish()` once on success and failure. Assert blank final text becomes a typed retryable error.

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter ArchivedAudioTranscriberTests
```

Expected: compilation fails because `ArchivedAudioTranscriber` does not exist.

- [ ] **Step 3: Implement the engine replay adapter**

Resolve `preferredInputFormat`, load chunks through `AudioArchiveReader`, start the engine, immediately start one collector task, feed chunks serially, call `finish`, await the collector, trim the latest snapshot, and use `defer`/error handling to finish the engine on every exit. Do not format, correct, persist, or inject here.

- [ ] **Step 4: Verify GREEN**

Run the focused command. Expected: all lifecycle cases pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MurmurYouTube/Transcription/ArchivedAudioTranscriber.swift Tests/MurmurYouTubeTests/ArchivedAudioTranscriberTests.swift
git commit -m "feat: replay archived audio locally"
```

---

### Task 3: Replace one history run durably

**Files:**
- Modify: `Sources/MurmurYouTube/Support/RunLog.swift`
- Modify: `Tests/MurmurYouTubeTests/CorrectionHistoryTests.swift`

**Interfaces:**
- Consumes: original run ID and complete replacement value.
- Produces: `RunLog.replaceDurably(id:with:) async -> Bool` through a testable `DurableRunReplacementTransaction`.

- [ ] **Step 1: Write failing transaction tests**

Assert successful persistence replaces exactly one matching run; a missing ID returns false without writing; a failed rewrite restores only the attempted run; a concurrent unrelated append survives rollback; and a newer mutation of the same UUID is never overwritten by stale rollback.

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter "Correction history"
```

Expected: compilation fails because the replacement transaction does not exist.

- [ ] **Step 3: Implement atomic replacement**

Mirror the durable append/correction transaction pattern: hydrate first, require `replacement.id == id`, optimistically replace one cached value, enqueue one complete JSONL rewrite, and on failure restore only when the cache still contains the exact attempted replacement. Regenerate the dashboard and reload `RunStore` on both optimistic write and rollback.

- [ ] **Step 4: Verify GREEN**

Run the focused command. Expected: existing correction behavior and new replacement cases pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MurmurYouTube/Support/RunLog.swift Tests/MurmurYouTubeTests/CorrectionHistoryTests.swift
git commit -m "feat: replace history runs durably"
```

---

### Task 4: Expose failed sessions as recoverable sources

**Files:**
- Create: `Sources/MurmurYouTube/History/RecoverableRecordingStore.swift`
- Modify: `Sources/MurmurYouTube/Support/RecordingSessionCoordinator.swift`
- Modify: `Sources/MurmurYouTube/MurmurYouTubeApp.swift`
- Modify: `Tests/MurmurYouTubeTests/RecordingSessionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `RecordingSessionStore.recoverableSessions()` and staged CAF URLs.
- Produces: immutable `RecoverableRecording` values and `completeRecoveredSession(sessionID:run:) async -> Bool` that never accepts an insertion closure.

- [ ] **Step 1: Write failing recovery-source tests**

Create real manifests for failed, ready, processed, completed, and cancelled sessions. Assert only sessions with an existing non-empty staged CAF become visible retry sources, ordered newest first, with typed status/failure detail. Assert non-inserting completion promotes audio/history once, marks the manifest completed, and repeated completion does not duplicate history.

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter RecordingSessionCoordinatorTests
```

Expected: compilation fails because recoverable snapshots and non-inserting completion do not exist.

- [ ] **Step 3: Implement the catalog and completion seam**

Map manifests inside `RecordingSessionCoordinator`; keep URLs and filesystem rules out of SwiftUI. Add `completeRecoveredSession` as a small wrapper over the existing private idempotent completion path. `RecoverableRecordingStore.refresh()` publishes snapshots on the main actor after launch reconciliation and after a confirmed retry.

- [ ] **Step 4: Verify GREEN**

Run the focused command. Expected: prior recovery tests and new visibility/idempotency tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MurmurYouTube/History/RecoverableRecordingStore.swift Sources/MurmurYouTube/Support/RecordingSessionCoordinator.swift Sources/MurmurYouTube/MurmurYouTubeApp.swift Tests/MurmurYouTubeTests/RecordingSessionCoordinatorTests.swift
git commit -m "feat: surface recoverable recordings"
```

---

### Task 5: Build preview-first retranscription and playback modules

**Files:**
- Create: `Sources/MurmurYouTube/History/RetranscriptionCoordinator.swift`
- Create: `Sources/MurmurYouTube/History/HistoryAudioPlayer.swift`
- Create: `Tests/MurmurYouTubeTests/RetranscriptionCoordinatorTests.swift`
- Create: `Tests/MurmurYouTubeTests/HistoryAudioPlayerTests.swift`

**Interfaces:**
- Consumes: `RetranscriptionSource`, `SpeechEngineChoice`, local engine factory, formatter, dictionary snapshot, durable history replacement, and durable session completion.
- Produces: immutable `RetranscriptionPreview`, explicit `confirm`, and `HistoryAudioPlayer.toggle(id:url:)`.

- [ ] **Step 1: Write failing preview/confirm tests**

Assert `preview` runs the selected local engine, cleanup, then dictionary in that order; returns candidate text without persistence; never calls an injected sentinel representing text insertion; confirmation replaces one history run while retaining UUID/date/audio duration/audio path and retaining the first `heardText`; failed-session confirmation creates one history row and completes the manifest; stale or mismatched previews fail; cancel is represented by dropping the preview and performs zero writes.

- [ ] **Step 2: Write failing playback tests**

Through an injected playback adapter, assert toggling a stopped URL starts it, toggling the active URL stops it, starting another URL stops the first, failed starts return an error state, and `stop()` clears state. The production adapter uses `NSSound(contentsOf:byReference:)` and retains the sound for its playback lifetime.

- [ ] **Step 3: Verify RED**

Run:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter RetranscriptionCoordinatorTests
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter HistoryAudioPlayerTests
```

Expected: compilation fails because both modules do not exist.

- [ ] **Step 4: Implement minimal modules**

The coordinator resolves the source URL, constructs only Apple or Parakeet, calls `ArchivedAudioTranscriber`, applies the current cleanup choice and deterministic dictionary correction, and returns a preview. For history confirmation, construct a replacement preserving stable identity and audio metadata while setting selected engine, new timing/text/corrections, and a correction record whose `heardText` remains the earliest heard text. For failed-session confirmation, transition the manifest through processed text and call non-inserting completion. The player owns all `NSSound` state; rows only send IDs and URLs.

- [ ] **Step 5: Verify GREEN**

Run both focused commands. Expected: all coordinator and playback cases pass with no calls to injection.

- [ ] **Step 6: Commit**

```bash
git add Sources/MurmurYouTube/History/RetranscriptionCoordinator.swift Sources/MurmurYouTube/History/HistoryAudioPlayer.swift Tests/MurmurYouTubeTests/RetranscriptionCoordinatorTests.swift Tests/MurmurYouTubeTests/HistoryAudioPlayerTests.swift
git commit -m "feat: preview local retranscriptions"
```

---

### Task 6: Add the approved history controls and prove the installed app

**Files:**
- Create: `Sources/MurmurYouTube/UI/RetranscriptionSheet.swift`
- Modify: `Sources/MurmurYouTube/UI/MainWindow.swift`
- Modify only if needed: `Sources/MurmurYouTube/UI/DesignSystem.swift`
- Create: `.impeccable/review/history-retranscription/verification.md`
- Create: `.impeccable/review/history-retranscription/` evidence images and sanitized fixture copies.

**Interfaces:**
- Consumes: `HistoryAudioPlayer`, `RetranscriptionCoordinator`, `RecoverableRecordingStore`, history runs, and recoverable snapshots.
- Produces: play/stop and retry actions, preview/cancel/confirm sheet, and recoverable status rows.

- [ ] **Step 1: Capture like-for-like pre-change surfaces**

Use the existing installed dark main/history evidence as the protected baseline. Capture the retained failed session state if it is visible only through filesystem evidence. Record light appearance as pending if proving it would require an unapproved global appearance mutation.

- [ ] **Step 2: Add the minimal SwiftUI surface**

In each row with audio, replace Finder reveal with play/stop and add one `arrow.clockwise` retry action. When recoverable snapshots exist, show one “Recoverable recordings” section above recent history with timestamp, failure/status copy, play, and retry. Present `RetranscriptionSheet` with an engine picker, explicit “Retranscribe” action, original/current text, candidate preview, inline error, “Cancel”, and “Replace history” or “Save to history”. Suspend dictation hotkeys while the sheet is open. Use only `DS` tokens; do not change the shell or existing row spacing outside these approved controls.

- [ ] **Step 3: Run source verification**

Run:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter VectorTests
make test
make app
```

Expected: dictionary vectors and the complete macOS suite pass; the app bundle builds without new warnings.

- [ ] **Step 4: Audit privacy and insertion paths**

Run:

```bash
rg -n "TextInjector|URLSession|http://|https://|Wispr" Sources/MurmurYouTube/History Sources/MurmurYouTube/UI/RetranscriptionSheet.swift Sources/MurmurYouTube/Transcription/ArchivedAudioTranscriber.swift
```

Expected: no `TextInjector`, network request, or Wispr reference in the new path.

- [ ] **Step 5: Install and exercise the exact surface**

Run `make install`, record version/build/executable checksum, then use the installed `/Applications/Murmure.app` to:

1. confirm the retained `e46730ca-27e7-4cb7-87eb-39482d53b351` failed fixture appears once;
2. play and stop its CAF in-app;
3. open retry, choose each locally available engine, and reach candidate/error without text appearing in a focused TextEdit document;
4. cancel once and prove manifest/history are byte-identical;
5. confirm one successful candidate when audible source audio permits it, prove one history row and completed manifest, then repeat recovery/relaunch to prove no duplicate;
6. play and retranscribe a completed history row, cancel once, confirm once, and prove stable UUID/audio path with changed history only after confirmation.

If the retained CAF contains no recognizable speech, preserve it for failure-path proof and create a fresh human-voice fixture through the installed app; do not manufacture a success claim from blank audio.

- [ ] **Step 6: Compare protected visuals**

Capture installed dark main/history, recoverable row, and preview sheet at the same window dimensions as the baseline. Compare shell, typography, colors, layout, and unaffected rows. Record any approved additions separately from accidental deltas. Keep light appearance explicitly unverified unless a matching existing system state is available without mutation.

- [ ] **Step 7: Write the evidence ledger**

Record artifact identity, automated commands, direct installed interactions, before/after image paths, history/manifests before and after cancel/confirm, no-insertion TextEdit evidence, protected visual matrix, and every unverified item in `.impeccable/review/history-retranscription/verification.md`.

- [ ] **Step 8: Commit**

```bash
git add Sources/MurmurYouTube/UI/RetranscriptionSheet.swift Sources/MurmurYouTube/UI/MainWindow.swift Sources/MurmurYouTube/UI/DesignSystem.swift .impeccable/review/history-retranscription
git commit -m "feat: add history playback and recovery"
```

---

## Self-review

- **Spec coverage:** Failed/recoverable states, in-app playback, engine selection, local replay, preview, explicit confirmation, history replacement, no injection, idempotent promotion, protected visuals, dictionary parity, and exact installed proof each map to a task.
- **Placeholder scan:** No TBD/TODO/later steps remain. Runtime failure cases and exact commands are named.
- **Type consistency:** `RetranscriptionSource`, `RetranscriptionPreview`, `ArchivedTranscription`, `replaceDurably`, `completeRecoveredSession`, and `HistoryAudioPlayer.toggle` have one stable spelling throughout.
- **Scope:** Language selection remains system-default until Phase 5; Phase 2 chooses only engine. No Windows, network, account, cloud, wake-word, or Intel work is introduced.
