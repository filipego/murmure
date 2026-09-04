# Command Snippets and Fast Live Text Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `Murmure add` snippet command, reduce Apple preview latency, and guarantee safe final replacement after delayed live insertion.

**Architecture:** Keep command parsing inside the pure snippet expander. Configure responsiveness inside the Apple speech adapter. Extend the live-text module's existing ownership state machine with bounded delayed observation rather than adding a second insertion system.

**Tech Stack:** Swift 6, Swift Testing, Apple SpeechAnalyzer, macOS Accessibility, AVFoundation.

## Global Constraints

- macOS 26 and Apple Speech remain the streaming path.
- Bare snippet triggers remain compatible.
- `Murmure add` is the fixed two-word command prefix.
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
- Produces: normalized trigger lookup supporting bare and `Murmure add` utterances.

- [ ] Add failing tests for `Murmure add, sample trigger`, case and punctuation variants, bare compatibility, and extra-word rejection.
- [ ] Run `make test` and confirm the prefixed cases fail while the existing suite remains green.
- [ ] Add one pure normalization step that removes the fixed prefix only when it begins the whole utterance.
- [ ] Run `make test` and confirm the snippet suite passes.

### Task 2: Faster Apple preliminary results

**Files:**
- Modify: `Sources/MurmurYouTube/Transcription/AppleSpeechEngine.swift`
- Test: `Tests/MurmurYouTubeTests/AppleSpeechEngineConfigurationTests.swift`

**Interfaces:**
- Consumes: `AppleSpeechEngine.makeTranscriber(locale:)`
- Produces: reporting options containing `volatileResults` and `fastResults`.

- [ ] Extract the reporting-option choice behind an internal test seam and add a failing assertion for both required options.
- [ ] Run the focused test and confirm `fastResults` is missing.
- [ ] Add `fastResults` beside `volatileResults` without changing finalization.
- [ ] Run the focused test and confirm it passes.

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
- [ ] Poll observation during the existing 500 ms paste window. Adopt ownership only after destination, selection, and inserted text verification succeeds.
- [ ] Keep unchanged and uncertain results history-only after the window expires.
- [ ] Run all live-text tests and confirm caret movement, cancellation, and duplicate prevention still pass.

### Task 4: Integrated verification and delivery

**Files:**
- Modify: `Resources/Info.plist`
- Modify: `dist/Murmure.app.zip`
- Modify: `dist/Murmure.app.zip.sha256`

**Interfaces:**
- Consumes: the three verified modules.
- Produces: one signed, installable Murmure update.

- [ ] Run `make test` and require all suites to pass.
- [ ] Run `make release`, verify the archive checksum, and install with `make install`.
- [ ] Verify the installed version and exercise a real text-field finalization path where possible.
- [ ] Commit and push the implementation. Publishing a public GitHub release requires explicit authorization.
