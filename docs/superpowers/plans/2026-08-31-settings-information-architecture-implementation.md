# Settings Information Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Murmure's one-page Settings with six focused categories, move Snippets into global navigation, and localize every new surface in English, French, and Spanish.

**Architecture:** A typed `SettingsCategory` model is the single source of truth for category order, titles, and symbols. `SettingsWindow` remains the deep module for preferences and renders one category at a time; `SnippetPanel` becomes the independent module for snippet content. `HubSection` exposes the new global destination.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Murmure's TSV localization catalog and design tokens.

## Global Constraints

- Preserve all recording and settings behavior.
- Preserve the field-recorder visual system; add tokens rather than view literals.
- Provide English, French, and Spanish for every new user-facing string.
- Use `make`, never bare `swift build`.
- Verify `/Applications/Murmure.app`, not only source or tests.

---

### Task 1: Lock the navigation models with tests

**Files:**
- Modify: `Tests/MurmurYouTubeTests/AppLocalizationTests.swift`
- Modify: `Sources/MurmurYouTube/Support/AppUpdateCoordinator.swift`
- Modify: `Sources/MurmurYouTube/UI/SettingsWindow.swift`

**Interfaces:**
- Produces: `SettingsCategory: String, CaseIterable, Identifiable` and `HubSection.snippets`.

- [ ] Write failing tests asserting the six Settings categories, their stable order, and the four hub destinations.
- [ ] Run `make test` and confirm the new expectations fail.
- [ ] Add the typed category and hub cases with centralized title and symbol metadata.
- [ ] Run `make test` and confirm the model tests pass.

### Task 2: Extract Snippets into a first-class panel

**Files:**
- Create: `Sources/MurmurYouTube/UI/SnippetPanel.swift`
- Modify: `Sources/MurmurYouTube/UI/SettingsWindow.swift`
- Modify: `Sources/MurmurYouTube/UI/MainWindow.swift`

**Interfaces:**
- Consumes: `HubSection.snippets`.
- Produces: `SnippetPanel: View`, owning `SnippetStore`, editor draft, deletion confirmation, and error state.

- [ ] Move the existing snippet list, enable, add, edit, and delete behavior into `SnippetPanel` without changing persistence logic.
- [ ] Route `.snippets` to `SnippetPanel()` in `MainWindow` and add a clear destination subtitle.
- [ ] Remove snippet state, sheets, alerts, and cards from `SettingsWindow`.
- [ ] Run `make test` and confirm all snippet and localization tests pass.

### Task 3: Build focused Settings navigation

**Files:**
- Modify: `Sources/MurmurYouTube/UI/SettingsWindow.swift`
- Modify: `Sources/MurmurYouTube/UI/DesignSystem.swift`

**Interfaces:**
- Consumes: `SettingsCategory`.
- Produces: a two-pane Settings surface with a persistent category rail and independently scrolling selected content.

- [ ] Add a selected-category state defaulting to `.dictation`.
- [ ] Add a design-token width for the local category rail.
- [ ] Group the existing controls into Dictation, Shortcuts, Microphone & sounds, Appearance, Privacy & storage, and Advanced & updates.
- [ ] Keep all existing bindings and controller callbacks unchanged.
- [ ] Run `make test` and `make`.

### Task 4: Localize and verify all three languages

**Files:**
- Modify: `Sources/MurmurYouTube/Localization/catalog.tsv`
- Modify: `Tests/MurmurYouTubeTests/AppLocalizationTests.swift`

**Interfaces:**
- Consumes: all new English source keys.
- Produces: complete French and Spanish translations for the new navigation and explanatory copy.

- [ ] Add exact English/French/Spanish rows for all new strings.
- [ ] Update localization tests to assert the distinction between “Display language” and “Language you speak.”
- [ ] Run `make test` and confirm catalog coverage passes.
- [ ] Install with `make install` and exercise Settings navigation and Snippets in English, French, and Spanish.
- [ ] Restore the installed app to English with Automatic spoken-language recognition.

