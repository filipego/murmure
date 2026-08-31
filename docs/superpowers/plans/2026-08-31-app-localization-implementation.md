# Murmure App Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a complete, persistent English, French, and Spanish interface with language selection at the start of onboarding and in Settings.

**Architecture:** A typed `AppLanguage` plus observable `AppLanguageStore` owns the interface locale independently from transcription settings. A single `L10n` catalog supplies deterministic English-key lookup, complete French and Spanish tables, and format-safe dynamic copy. Every window root observes the store and all active native user-facing strings cross the localization boundary.

**Tech Stack:** Swift 6.2, SwiftUI, Observation, Swift Testing, UserDefaults, AppKit, macOS 26.

## Global Constraints

- Use `make`, never bare `swift build`.
- Do not change DesignSystem tokens, layout structure, colors, typography, sizing, imagery, or animations.
- Red remains recording-only. Amber and green remain instrumentation-only.
- Keep interface language independent from transcription language and cleanup language.
- Do not add a network service, dependency, translation API, or App Store requirement.
- Preserve code-signing, storage, permissions, update, history, dictionary, and correction behavior.

---

### Task 1: Interface language domain and persistence

**Files:**
- Create: `Sources/MurmurYouTube/Support/AppLocalization.swift`
- Create: `Tests/MurmurYouTubeTests/AppLocalizationTests.swift`

**Interfaces:**
- Produces: `AppLanguage`, `AppLanguageStore`, `L10n.text`, `L10n.format`, and catalog validation hooks.
- Consumes: `UserDefaults` and `Locale.preferredLanguages` at the persistence boundary.

- [ ] Write tests asserting `fr` and `es` stable identifiers, Mac-language defaulting, English fallback, explicit persistence, and independence from `TranscriptionLanguageOption`.
- [ ] Run `swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter AppLocalizationTests` and confirm the missing types fail compilation.
- [ ] Implement the minimal enum and store to pass persistence and defaulting tests.
- [ ] Add English-key lookup, French and Spanish tables, and placeholder inspection.
- [ ] Add tests that every catalog key exists in both translations and formatted placeholders match English.
- [ ] Run the focused tests and confirm they pass.

### Task 2: Language-aware application roots and onboarding

**Files:**
- Modify: `Sources/MurmurYouTube/MurmurYouTubeApp.swift`
- Modify: `Sources/MurmurYouTube/Support/OnboardingState.swift`
- Modify: `Sources/MurmurYouTube/UI/OnboardingWindow.swift`
- Modify: `Tests/MurmurYouTubeTests/OnboardingStateTests.swift`
- Test: `Tests/MurmurYouTubeTests/AppLocalizationTests.swift`

**Interfaces:**
- Consumes: `AppLanguageStore.shared` and `L10n` from Task 1.
- Produces: first-step language selection and reactive localization roots for every scene.

- [ ] Write a failing onboarding policy test proving `.language` is the first step and advances without permission readiness.
- [ ] Write a failing localization test proving changing interface language leaves the transcription option unchanged.
- [ ] Run the focused tests and confirm both fail for the absent behavior.
- [ ] Add the language step, native-name picker, localized onboarding copy, and observable application root wrappers.
- [ ] Localize scene titles, AppKit compatibility alert, menu bar copy, actions, help, and status strings.
- [ ] Run the focused tests and confirm they pass.

### Task 3: Primary windows and settings

**Files:**
- Modify: `Sources/MurmurYouTube/UI/MainWindow.swift`
- Modify: `Sources/MurmurYouTube/UI/DictionaryPanel.swift`
- Modify: `Sources/MurmurYouTube/UI/SettingsWindow.swift`
- Modify: `Sources/MurmurYouTube/Support/Settings.swift`
- Modify: `Sources/MurmurYouTube/Transcription/TranscriptionLanguage.swift`
- Test: `Tests/MurmurYouTubeTests/AppLocalizationTests.swift`

**Interfaces:**
- Consumes: `L10n` and `AppLanguageStore`.
- Produces: localized Home, Dictionary, Settings, display names, statuses, errors, help, and accessibility labels.

- [ ] Add failing key-coverage assertions for every primary-window and settings key.
- [ ] Run focused tests and confirm missing catalog entries fail.
- [ ] Convert primary-window literals and computed copy to `L10n.text` or `L10n.format`.
- [ ] Add the persistent App Language picker near the top of Settings without changing layout tokens.
- [ ] Add complete French and Spanish translations for the converted keys.
- [ ] Run focused tests and confirm they pass.

### Task 4: Secondary workflows and domain-facing errors

**Files:**
- Modify: `Sources/MurmurYouTube/UI/CommandModeWindow.swift`
- Modify: `Sources/MurmurYouTube/UI/ComparisonWindow.swift`
- Modify: `Sources/MurmurYouTube/UI/CorrectionEditor.swift`
- Modify: `Sources/MurmurYouTube/UI/HUDView.swift`
- Modify: `Sources/MurmurYouTube/UI/RetranscriptionSheet.swift`
- Modify: `Sources/MurmurYouTube/UI/ShortcutRecorderSheet.swift`
- Modify: `Sources/MurmurYouTube/UI/SnippetEditorSheet.swift`
- Modify: user-visible error and status producers under `Sources/MurmurYouTube/Core`, `Support`, and `History` only where they cross into UI.
- Test: `Tests/MurmurYouTubeTests/AppLocalizationTests.swift`

**Interfaces:**
- Consumes: the same localization boundary.
- Produces: localized secondary windows, sheets, HUD, validation, recovery, and error states.

- [ ] Add failing catalog assertions for secondary-workflow copy and known domain errors.
- [ ] Run focused tests and confirm missing entries fail.
- [ ] Convert all active user-facing secondary copy and known errors.
- [ ] Preserve user-authored text, device names, dictated content, shortcuts, and system-provided error descriptions verbatim.
- [ ] Complete French and Spanish catalog entries.
- [ ] Run focused tests and confirm they pass.

### Task 5: Technical and exact-surface verification

**Files:**
- Modify only localization defects discovered by verification.

**Interfaces:**
- Consumes: the completed localized application.
- Produces: verified tests, signed bundle, installed app, and surface ledger.

- [ ] Run `make test` and require zero failures.
- [ ] Run `make app` and verify the signed staged bundle.
- [ ] Inspect the diff for untranslated active UI literals and credential-like content.
- [ ] Run `make install` and record the installed bundle version and checksum.
- [ ] In the installed app, exercise English, French, and Spanish on Home, Dictionary, Settings, onboarding, and a secondary workflow.
- [ ] Compare each localized state with the English baseline for layout structure, tokens, clipping, truncation, and unintended visual differences.
- [ ] Restore English and the user's original transcription selection after proof.
