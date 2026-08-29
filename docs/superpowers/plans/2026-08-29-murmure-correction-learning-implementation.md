# Murmure Correction Learning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add text-first, optionally voice-assisted correction that updates local history and safely teaches future dictations in one save.

**Architecture:** A pure learner in `MurmurDictionary` derives and validates a constrained rule. Existing main-actor stores own persistence. A dedicated correction voice controller fills an editable SwiftUI draft without entering the normal injection pipeline.

**Tech Stack:** Swift 6, SwiftUI, Observation, AVFoundation, Apple SpeechAnalyzer, Swift Testing, SwiftPM, Make.

## Global Constraints

- Preserve the existing macOS dictation path and its ordered audio-buffer behavior.
- Keep all persisted data under the existing `MurmureDataStore` root.
- Never delete or rewrite unrelated external-drive files.
- Keep `shared/dictionary-test-vectors.json` unchanged because correction application semantics do not change.
- Use `DS` tokens for every new visual value. Red means active recording only.
- Typed text is authoritative. Voice fills an editable draft and never saves automatically.
- Save is idempotent and updates history before upserting a future rule.

---

## File map

- Create `Sources/MurmurDictionary/CorrectionLearner.swift` for pure planning and dictionary upsert.
- Create `Tests/MurmurDictionaryTests/CorrectionLearnerTests.swift` for learner and idempotence behavior.
- Modify `Sources/MurmurYouTube/Support/RunLog.swift` for backward-compatible correction records and atomic run updates.
- Modify `Package.swift` and create `Tests/MurmurYouTubeTests/CorrectionHistoryTests.swift` for the history-model compatibility seam.
- Modify `Sources/MurmurYouTube/Dictionary/DictionaryStore.swift` for learned-rule upsert.
- Create `Sources/MurmurYouTube/Core/CorrectionVoiceController.swift` for isolated correction recording.
- Modify `Sources/MurmurYouTube/Core/DictationController.swift` only for idempotent modal hotkey suspension.
- Create `Sources/MurmurYouTube/UI/CorrectionEditor.swift` for correction, playback, voice fill, preview, and save.
- Modify `Sources/MurmurYouTube/UI/MainWindow.swift` to open the editor from history.
- Modify `Sources/MurmurYouTube/UI/DesignSystem.swift` for sheet and editor size tokens.
- Modify `README.md` to explain correction learning.

### Task 1: Pure correction learner

**Files:**

- Create: `Tests/MurmurDictionaryTests/CorrectionLearnerTests.swift`
- Create: `Sources/MurmurDictionary/CorrectionLearner.swift`

**Interfaces:**

- Produces: `CorrectionLearner.plan(heard:intended:) -> CorrectionLearningPlan`
- Produces: `CorrectionLearner.upserting(_:into:) -> [DictionaryEntry]`
- Produces: `CorrectionRuleSuggestion`, `CorrectionLearningPlan`, and `CorrectionLearningUnavailableReason`

- [ ] **Step 1: Write failing tests**

Cover `a lie -> a line`, the banana/Mariana context rule, repeated-token expansion, NFC,
punctuation-only history behavior, insertion/deletion rejection, unsafe syntax, edit caps,
duplicate upsert, conflicting-trigger replacement, disabled-rule reenable, and most-recent-first
ordering.

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/scratch" --filter CorrectionLearnerTests
```

Expected: failure because `CorrectionLearner` and its value types do not exist.

- [ ] **Step 3: Implement the pure learner**

Use Unicode word ranges, exact prefix/suffix comparison, two-word minimum triggers, six-word and
160-character caps, and full-transcript validation through `DictionaryCorrector`.

- [ ] **Step 4: Verify GREEN**

Run the focused command again, then:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/scratch"
```

Expected: all tests pass and the shared vectors remain green.

### Task 2: History, voice, and correction UI

**Files:**

- Modify: `Sources/MurmurYouTube/Support/RunLog.swift`
- Modify: `Package.swift`
- Create: `Tests/MurmurYouTubeTests/CorrectionHistoryTests.swift`
- Modify: `Sources/MurmurYouTube/Dictionary/DictionaryStore.swift`
- Create: `Sources/MurmurYouTube/Core/CorrectionVoiceController.swift`
- Modify: `Sources/MurmurYouTube/Core/DictationController.swift`
- Create: `Sources/MurmurYouTube/UI/CorrectionEditor.swift`
- Modify: `Sources/MurmurYouTube/UI/MainWindow.swift`
- Modify: `Sources/MurmurYouTube/UI/DesignSystem.swift`

**Interfaces:**

- Consumes: `CorrectionLearningPlan.suggestion`
- Produces: `RunLog.correct(id:intendedText:inputMethod:rememberedRule:) -> Bool`
- Produces: `DictionaryStore.remember(_:)`
- Produces: `CorrectionVoiceController.start(completion:)`, `stop()`, and `cancel()`
- Produces: `DictationController.suspendHotkeyForModalInput()` and `resumeHotkeyAfterModalInput()`

- [ ] **Step 1: Write and run failing history-model tests**

Add an executable-target test dependency and cover decoding a legacy run with no correction,
preserving the first heard text across repeated edits, retaining the original audio path, and
storing a hear/write snapshot instead of a dictionary UUID. Run the focused test and confirm it
fails because the correction record and pure run-update method do not exist.

- [ ] **Step 2: Add backward-compatible history data**

Make `DictationRun.text` mutable. Add optional `TranscriptCorrectionRecord` decoding. Implement
`RunLog.correct` so it preserves the first heard text and the existing audio path, rewrites JSONL
atomically, regenerates the dashboard, and reloads `RunStore`.

- [ ] **Step 3: Connect idempotent dictionary learning**

Make `DictionaryStore.remember` replace its in-memory entries with
`CorrectionLearner.upserting`, then persist through the existing external-drive path.

- [ ] **Step 4: Add isolated correction voice capture**

Copy the proven ordered stream lifecycle into `CorrectionVoiceController`. Return a typed outcome
for transcript, blank audio, failure, or cancellation. Do not call injection, history, audio
archive, Wispr Flow, compare mode, cleanup, or dictionary code.

- [ ] **Step 5: Add modal hotkey suspension**

Stop only the global hotkey while the editor is visible. Resume it on every dismissal path.
Repeated suspend or resume calls must converge to the same state.

- [ ] **Step 6: Build the correction editor**

Show original text, retained-audio playback, editable intended text, optional Dictate/Stop,
remember toggle defaulting on, exact rule preview, safe history-only explanation, Cancel, and one
Save correction action. Save history first, then upsert the rule. Voice completion only replaces
the editable draft.

- [ ] **Step 7: Expose Correct from history**

Add one neutral pencil action and a correction-status label. Disable opening while normal
dictation is active. Present one sheet owned by `HomePanel`.

- [ ] **Step 8: Build verification**

Run:

```bash
make app
codesign --verify --deep --strict "$HOME/Library/Caches/MurmurYouTubeBuild/Murmure.app"
```

Expected: both commands exit zero.

### Task 3: Documentation, distribution, and installed surface

**Files:**

- Modify: `README.md`
- Regenerate: `dist/Murmure.app.zip`
- Regenerate: `dist/Murmure.app.zip.sha256`

**Interfaces:**

- Consumes: the finished correction workflow and repository Makefile.
- Produces: friend-shareable source instructions and a refreshed signed archive.

- [ ] **Step 1: Document correction learning**

Add the Correct workflow to the short usage guide. State that a safe learned pair updates the
local dictionary and that voice remains editable before Save.

- [ ] **Step 2: Run the complete verification suite**

Run:

```bash
swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/scratch"
make app
```

Expected: tests pass and the app bundle builds.

- [ ] **Step 3: Install and verify the real app**

Run `make install`, then confirm `/Applications/Murmure.app` has bundle identifier
`ai.pivotstudio.murmur-youtube`, a strict valid signature, and a running `MurmurYouTube` process.
Open the installed correction sheet and verify the original user scenario on that surface.

- [ ] **Step 4: Refresh the share archive**

Run `make share`, verify the SHA-256 sidecar against the ZIP, and confirm the ZIP contains
`Murmure.app/Contents/MacOS/MurmurYouTube`.

- [ ] **Step 5: Review, commit, and push**

Review the complete diff against this plan and the project rules. Commit only intended files with
a Conventional Commit message, then push `main` to `origin` without force.

## Self-review

- Spec coverage: Tasks 1 through 3 cover every acceptance criterion.
- Placeholder scan: the plan contains no deferred implementation markers.
- Type consistency: Task 2 consumes the exact learner interfaces produced by Task 1.
- Surface coverage: Task 3 checks source tests, signed bundle, installed app, and share archive.
