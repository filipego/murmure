# Localized Snippet Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `Voice add` with one localized insertion command for every supported spoken language and teach the command inside the Snippets interface and complete guide.

**Architecture:** A deep `SnippetCommandLexicon` module owns command selection and display examples. `SnippetExpander` receives the spoken-language option captured for the dictation operation, keeping matching pure and testable. SwiftUI reads the same module so displayed instructions cannot drift from runtime behavior.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, tab-separated localization catalog, HTML-to-PDF guide generation.

## Global Constraints

- The command follows Language you speak, not Display language.
- Automatic accepts every supported command.
- An explicit language accepts only its localized command.
- Existing whole-utterance snippet matching remains unchanged.
- No visual design changes beyond replacing the instructional copy in existing surfaces.
- Build with `make`, never bare `swift build`.

---

### Task 1: Localized command matching

**Files:**
- Modify: `Tests/MurmurYouTubeTests/SnippetExpanderTests.swift`
- Create: `Sources/MurmurYouTube/Support/SnippetCommandLexicon.swift`
- Modify: `Sources/MurmurYouTube/Support/SnippetDomain.swift`
- Modify: `Sources/MurmurYouTube/Support/SnippetStore.swift`
- Modify: `Sources/MurmurYouTube/Core/DictationController.swift`

**Interfaces:**
- Produces: `SnippetCommandLexicon.commands(for:) -> [String]`
- Produces: `SnippetCommandLexicon.primaryCommand(for:) -> String`
- Changes: `SnippetExpander(entries:language:)`
- Changes: `SnippetStore.expand(_:language:)`

- [x] **Step 1: Write failing tests for all explicit languages, Automatic, language isolation, boundaries, Unicode normalization, trailing speech, and whole-utterance compatibility.**
- [x] **Step 2: Run `swift test --scratch-path /tmp/murmure-localized-snippets --filter SnippetExpanderTests` and confirm the new tests fail because the language-aware interface does not exist.**
- [x] **Step 3: Add the command lexicon and pass the operation's captured language through the store to the expander.**
- [x] **Step 4: Run the focused test command and confirm every snippet test passes.**

### Task 2: Discoverable interface copy

**Files:**
- Modify: `Sources/MurmurYouTube/UI/SnippetPanel.swift`
- Modify: `Sources/MurmurYouTube/UI/SnippetEditorSheet.swift`
- Modify: `Sources/MurmurYouTube/Localization/catalog.tsv`
- Modify: `Tests/MurmurYouTubeTests/AppLocalizationTests.swift`

**Interfaces:**
- Consumes: `SnippetCommandLexicon.primaryCommand(for:)`
- Produces: localized English, French, and Spanish instructions with a runtime command example.

- [x] **Step 1: Write failing localization and command-example tests.**
- [x] **Step 2: Run the focused localization tests and confirm the required copy is absent.**
- [x] **Step 3: Replace `Voice add` copy in the Snippets destination and editor with formatted copy using the active command.**
- [x] **Step 4: Add complete English, French, and Spanish catalog rows and run the focused tests.**

### Task 3: Guide, runtime proof, and release

**Files:**
- Modify: `docs/Murmure-Complete-User-Guide.html`
- Modify: `docs/Murmure-Complete-User-Guide.pdf`
- Update: relevant images under `docs/assets/murmure-guide/` if the rendered Snippets screen changes materially.

- [x] **Step 1: Update every guide reference and example from `Voice add` to Insert, Insère, and Inserta.**
- [x] **Step 2: Run the full test suite with `make test` or the repository's equivalent Make target, then build with `make`.**
- [x] **Step 3: Install the app, verify the Snippets destination in the real app, and capture a privacy-safe current screenshot if needed.**
- [x] **Step 4: Regenerate the PDF, verify 20 A4 pages, and inspect every affected page for clipping.**
- [ ] **Step 5: Run `git diff --check`, commit only intended files, push `main`, and verify `origin/main...HEAD` is `0 0`.**
