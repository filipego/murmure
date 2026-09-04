# Command Snippets and Fast Live Text Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `Voice add` snippet command, reduce Apple preview latency, and guarantee final replacement inside fields with limited Accessibility support.

**Architecture:** Keep command parsing inside the pure snippet expander. Configure responsiveness inside the Apple speech adapter. Preserve verified Accessibility replacement where supported and let the same live-text ownership state machine use focused-field keystrokes when a target does not expose usable text ranges.

**Tech Stack:** Swift 6, Swift Testing, Apple SpeechAnalyzer, macOS Accessibility, AVFoundation.

## Global Constraints

- macOS 26 and Apple Speech remain the streaming path.
- Bare snippet triggers remain compatible.
- `Voice add` is the fixed two-word command prefix.
- Final cleanup, snippet expansion, dictionary correction, and persistence ordering remains unchanged.
- No user snippet replacement appears in source, tests, logs, or tool output.
- `docs/research/` remains untouched.

---

### Task 1: Spoken snippet command

**Files:**
- Modify: `Sources/MurmurYouTube/Support/SnippetDomain.swift`
- Test: `Tests/MurmurYouTubeTests/SnippetExpanderTests.swift`

**Interfaces:**
- Consumes: `SnippetExpander.expand(_:) -> SnippetExpansionResult`
- Produces: normalized trigger lookup supporting bare and `Voice add` utterances.

- [x] Add failing tests for `Voice add, sample trigger`, case and punctuation variants, bare compatibility, and extra-word rejection.
- [x] Run `make test` and confirm the prefixed cases fail while the existing suite remains green.
- [x] Add one pure normalization step that removes the fixed prefix only when it begins the whole utterance.
- [x] Run `make test` and confirm the snippet suite passes.

### Task 2: Faster Apple preliminary results

**Files:**
- Modify: `Sources/MurmurYouTube/Transcription/AppleSpeechEngine.swift`
- Test: `Tests/MurmurYouTubeTests/AppleSpeechEngineConfigurationTests.swift`

**Interfaces:**
- Consumes: `AppleSpeechEngine.makeTranscriber(locale:)`
- Produces: reporting options containing `volatileResults` and `fastResults`.

- [x] Extract the reporting-option choice behind an internal test seam and add a failing assertion for both required options.
- [x] Run the focused test and confirm `fastResults` is missing.
- [x] Add `fastResults` beside `volatileResults` without changing finalization.
- [x] Run the focused test and confirm it passes.

### Task 3: Delayed live-preview ownership

**Files:**
- Modify: `Sources/MurmurYouTube/Core/LiveTextInsertionSession.swift`
- Modify: `Sources/MurmurYouTube/Core/TextInjector.swift`
- Test: `Tests/MurmurYouTubeTests/LiveTextInsertionSessionTests.swift`

**Interfaces:**
- Consumes: posted paste plus repeated `LiveTextReplacementObservation` values.
- Produces: a verified owned preview or the existing safe history-only disposition.

- [ ] Add a failing test where the posted paste is initially unchanged, becomes observable within the bounded window, and is then replaced by final text.
- [ ] Run the focused test and confirm finalization remains history-only.
- [x] Add a focused-field keystroke plan that retains the stable prefix, deletes the revised grapheme tail, and inserts the replacement tail when Accessibility ranges are unavailable.
- [x] Keep unchanged and uncertain results history-only after the window expires.
- [x] Run all live-text tests and confirm caret movement, cancellation, and duplicate prevention still pass.

### Task 4: Integrated verification and delivery

**Files:**
- Modify: `Resources/Info.plist`
- Modify: `dist/Murmure.app.zip`
- Modify: `dist/Murmure.app.zip.sha256`

**Interfaces:**
- Consumes: the three verified modules.
- Produces: one signed, installable Murmure update.

- [x] Run `make test` and require all suites to pass.
- [ ] Run `make release`, verify the archive checksum, and install with `make install`.
- [ ] Verify the installed version and exercise a real text-field finalization path where possible.
- [ ] Commit and push the implementation. Publishing a public GitHub release requires explicit authorization.
