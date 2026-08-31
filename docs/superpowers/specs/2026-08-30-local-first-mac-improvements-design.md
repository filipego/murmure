# Local-First Mac Improvements Design

Date: 2026-08-30

Status: Awaiting written-spec review

## Goal

Make Murmure a substantially more dependable and useful local dictation tool for the operator, friends, and coworkers on Macs. The modern application remains optimized for Apple Silicon and macOS 26. A separately contained legacy effort investigates a reduced Intel edition without weakening the modern application.

## Product contract

Murmure remains:

- free to operate;
- local-first and usable without an account;
- Mac-only;
- private by default, with no dictation, audio, history, dictionary, snippet, selected text, or diagnostics sent to a server;
- visually consistent with the existing 1980s field-recorder design system;
- safe for the current operator's external-drive workflow and ordinary Application Support storage on friends' Macs;
- deterministic about dictionary corrections through `shared/dictionary-test-vectors.json`.

This program adds:

- crash-safe recording recovery and retry;
- dependable storage failover;
- history playback and retranscription;
- hands-free dictation;
- microphone selection and device recovery;
- explicit multilingual dictation with language-aware cleanup;
- richer hotkey configuration;
- local snippets;
- first-run onboarding;
- easier friend installation and diagnostics;
- local selected-text Command Mode;
- an isolated Intel compatibility investigation and, only if proven feasible, a reduced legacy edition.

The existing Wispr Flow comparison hook is removed from production behavior. Compare mode becomes Apple versus Parakeet only. GitHub release checks and model downloads may use the network, but microphone audio, transcript text, selected text, dictionary data, snippets, history, and diagnostics may not be included in those requests.

## Explicit exclusions

The work does not include:

- Windows implementation or verification;
- accounts, authentication, synchronization, subscriptions, billing, referrals, teams, SSO, or enterprise features;
- mandatory cloud processing, paid APIs, owned inference servers, or telemetry services;
- MCP tools or general-purpose agent integrations;
- wake-word or always-listening activation;
- a visual redesign;
- commercial distribution, marketing, or monetization;
- weakening the modern Apple Silicon application to the Intel feature floor.

## Design principles and resulting decisions

### Foundational Thinking

The new foundation is a durable recording session, not a transcript string. A recording can exist before transcription, survive failure, be retried, and eventually produce a completed history run. This changes the core data shape from scattered controller state to a persisted session state machine.

### Redesign from First Principles

If recovery, multiple trigger modes, explicit languages, and retranscription had existed on day one, `DictationController` would orchestrate deep modules rather than own capture, buffering, engine lifecycle, archival, formatting, persistence, and injection itself. The program introduces those seams incrementally without rewriting working dictionary, updater, or presentation code.

### Boundary Discipline

Framework-specific behavior stays in adapters:

- CoreAudio device enumeration and selection stay behind the audio-input seam.
- Speech framework locale/model behavior stays behind the language and engine seams.
- Foundation Models selected-text transformation stays behind the command-processing seam.
- Filesystem recovery and external-drive failover stay behind the session-store seam.

Pure session, cleanup, snippet, retry, and hotkey-gesture policies remain testable without microphones, event taps, models, or disks.

### Type System Discipline

Session status, trigger mode, language selection, microphone selection, retry intent, and command review state use enums and value types. Invalid combinations must not be represented by unrelated booleans.

### Make Operations Idempotent

Recovery, history promotion, external-drive reconciliation, retry, onboarding completion, model installation, and update installation must converge when repeated after interruption. A repeated recovery pass may not duplicate history, audio, dictionary changes, snippets, or pasted text.

### Laziness Protocol and Subtract Before You Add

Existing working modules remain in place. New seams replace behavior only where the approved features need them. The program does not add accounts, plugin systems, generic workflow engines, or a new design system.

### Experience First

The order favors never losing speech, predictable languages, hands-free use, and understandable errors before advanced Command Mode. No recording is automatically pasted after a retry or recovery.

### Prove It Works

Unit tests prove policy. `make test` proves the source suite. Bundled and installed-app exercises prove microphone, hotkey, focus, permissions, history, recovery, language, and update behavior. Intel support is not claimed until exercised on the actual Intel Mac.

## Architecture alternatives

### Alternative A: Add every feature directly to current types

This would extend `DictationController`, `Settings`, `HotkeyMonitor`, `AudioCapture`, `RunLog`, and large SwiftUI views in place. It minimizes initial files but increases hidden state, makes recovery hard to reason about, and couples every test to the main actor.

Rejected.

### Alternative B: Introduce focused deep modules around the existing application

`DictationController` remains the UI-facing orchestrator. Durable session storage, audio input, language resolution, hotkey gesture policy, snippets, retranscription, diagnostics, onboarding, and Command Mode each receive a small interface. Existing dictionary, updater, design system, text injector, and engine adapters are reused.

Selected. It provides the approved behavior while preserving current working paths and visual identity.

### Alternative C: Rewrite the application around a new architecture

A rewrite could create cleaner boundaries immediately but would discard proven permission, dictionary, correction-learning, text-insertion, update, and external-storage behavior. It would also make surface parity much harder to prove.

Rejected.

## Core data shapes

### Durable recording session

```swift
struct RecordingSessionManifest: Codable, Sendable, Identifiable {
    let schemaVersion: Int
    let id: UUID
    let startedAt: Date
    var releasedAt: Date?
    let trigger: RecordingTrigger
    let engine: SpeechEngineChoice
    let language: TranscriptionLanguageSelection
    var audioFile: String?
    var status: RecordingSessionStatus
}

enum RecordingSessionStatus: Codable, Sendable, Equatable {
    case recording
    case readyForTranscription
    case processing
    case processed(finalText: String)
    case failed(RecordingFailure)
    case completed(runID: UUID)
    case cancelled
}
```

The persisted manifest is a transaction journal. Audio is staged in local Application Support first. The processed state makes final text durable before insertion or history promotion. Recovery never inserts processed text automatically, preventing duplicate paste after a crash. Promotion to preferred storage and completed history is idempotent. A completed manifest can be cleaned only after its history row and audio destination are confirmed.

### Recording trigger

```swift
enum RecordingTrigger: Codable, Sendable, Equatable {
    case holdToTalk(HotkeyBinding)
    case handsFree(HotkeyBinding)
    case mainButton
    case retry(sourceRunID: UUID)
}
```

Hands-free recording begins from a dedicated binding. Enter or the same binding finishes it. Escape cancels it. Enter and Escape are observed only during an active hands-free session.

### Language selection

```swift
enum TranscriptionLanguageSelection: Codable, Sendable, Equatable {
    case systemDefault
    case locale(identifier: String)
}

struct TranscriptionLanguageOption: Sendable, Identifiable, Equatable {
    let id: String
    let localizedName: String
    let isInstalled: Bool
    let supportsSmartCleanup: Bool
}
```

Apple transcription receives the resolved locale explicitly. Unsupported choices produce a visible error and never silently fall back to English. Parakeet is presented as multilingual automatic detection only for its verified language set.

### Language-aware cleanup

```swift
struct CleanupProfile: Sendable, Equatable {
    let localeIdentifier: String
    let fillerPhrases: [String]
    let spokenPunctuation: [String: String]
    let capitalizationPolicy: CapitalizationPolicy
}
```

English, Spanish, and French receive explicit deterministic profiles. An unknown language receives only language-neutral whitespace normalization. Smart cleanup is enabled only when the system model supports the selected language; otherwise the app explains the fallback.

### Microphone selection

```swift
enum MicrophoneSelection: Codable, Sendable, Equatable {
    case systemDefault
    case device(uniqueID: String, displayName: String)
}

struct AudioInputDevice: Sendable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let transport: AudioInputTransport
    let isSystemDefault: Bool
}
```

The audio-input adapter resolves persisted selections, detects disappearance, and returns a typed fallback outcome. It does not silently change the system-wide default microphone.

### Hotkey binding and gesture

```swift
struct HotkeyBinding: Codable, Sendable, Equatable {
    let keyCode: Int64
    let requiredFlags: UInt64
    let side: ModifierSide?
    let gesture: HotkeyGesture
    let consumption: EventConsumptionPolicy
}

enum HotkeyGesture: String, Codable, Sendable {
    case hold
    case doubleTapHold
    case toggle
}
```

Conflict validation runs before persistence. Existing Right Option, fn, and Right Command choices migrate into this shape. International-layout risks are surfaced instead of hidden.

### Snippet

```swift
struct SnippetEntry: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    var trigger: String
    var replacement: String
    var isEnabled: Bool
}
```

Snippets run after cleanup and before guaranteed dictionary correction. Exact whole-utterance triggers are implemented first. This avoids surprising replacements inside ordinary prose.

### Diagnostics

```swift
struct DiagnosticsSnapshot: Sendable, Equatable {
    let appVersion: String
    let macOSVersion: String
    let architecture: String
    let microphone: String
    let engine: String
    let language: String
    let modelState: String
    let permissionStates: [String: String]
    let storageState: String
    let lastFailure: String?
}
```

The exported snapshot excludes transcript text, selected text, dictionary entries, snippets, audio contents, filenames derived from speech, and unrelated filesystem paths.

### Local Command Mode

```swift
struct LocalCommandRequest: Sendable, Equatable {
    let selectedText: String
    let instruction: String
    let sourceApplicationName: String?
}

enum LocalCommandReviewState: Equatable {
    case idle
    case recordingInstruction
    case processing
    case review(original: String, proposed: String)
    case failed(String)
}
```

Selected text and the spoken instruction go only to Foundation Models. The proposed result appears in a review window. Paste or replace requires explicit confirmation. Unavailable Apple Intelligence produces a clear local-only limitation; it never triggers a network fallback.

## Deep modules and seams

### `RecordingSessionStore`

Interface responsibilities:

- begin a durable session;
- append or finalize staged audio in capture order;
- transition the manifest through legal states;
- enumerate recoverable sessions;
- promote one session to final history and preferred storage idempotently;
- retain failure details for retry.

The implementation owns local staging, manifest atomic writes, reconciliation, and external-drive copy verification. Callers do not manage paths or partial files.

### `DictationPipeline`

Interface responsibilities:

- accept a completed local recording plus engine/language/cleanup/snippet configuration;
- return a typed final result or typed retryable failure;
- never inject text itself.

The controller decides whether a live result is inserted. History retry and crash recovery use the same pipeline without accidental insertion.

### `TranscriptionLanguageCatalog`

Interface responsibilities:

- enumerate supported Apple locales;
- mark installed models;
- resolve system-default and explicit selections;
- install a selected model with progress;
- report cleanup compatibility.

### `AudioInputCatalog` and `AudioCapture`

The catalog enumerates and observes device changes. Capture accepts a resolved device and output format. Device-specific CoreAudio calls stay inside the adapter.

### `HotkeyRegistry`

The registry owns two actions, hold-to-talk and hands-free. It validates conflicts, interprets gestures, and exposes press/release/toggle events. `DictationController` receives semantic actions rather than raw CGEvent state.

### `SnippetStore` and `SnippetExpander`

The store owns persistence and CRUD. The pure expander applies an ordered snapshot. Dictionary correction remains the final deterministic pass.

### `RetranscriptionCoordinator`

The coordinator loads archived audio, runs the standard pipeline without injection, and returns a preview. History replacement happens only after confirmation and preserves the original heard text.

### `OnboardingState`

Onboarding persists completed steps and can be reset from Settings. Permission, hotkey, microphone, language, and test-dictation checks call the same production modules as the main app.

### `DiagnosticsCollector`

The collector creates a sanitized snapshot from typed providers. SwiftUI only renders or exports it.

### `LocalCommandController`

The controller obtains selected text through the existing Accessibility seam, records an instruction through the standard audio/language path, calls a local Foundation Models adapter, and holds the review state. It never pastes without confirmation.

## Runtime flows

### Normal hold-to-talk

1. The hotkey registry emits hold start.
2. The controller creates a durable session manifest.
3. Capture begins for the selected microphone and engine format.
4. Ordered audio reaches both the engine and local staging.
5. Release finalizes staged audio before the session can be considered ready.
6. The pipeline finishes transcription, language-aware cleanup, snippets, and dictionary correction.
7. The pipeline persists the processed final text in the session manifest.
8. Only the live controller path inserts that text. Relaunch recovery never inserts it.
9. The session store promotes audio and history idempotently.
10. The manifest becomes completed and is eligible for cleanup.

### Hands-free

The flow is identical except activation is toggle-based. The same binding or Enter finishes. Escape transitions the session to cancelled and removes only the current staged artifact after the user-visible cancellation succeeds.

### Failure and relaunch recovery

1. A framework, model, storage, or process failure leaves a staged audio file and manifest.
2. The history surface shows the session as failed or recoverable.
3. Relaunch scans manifests and reconciles completed promotions without duplication.
4. Retry uses the standard pipeline and presents a preview.
5. Confirmation promotes or replaces history. It does not insert into another app.

### External drive unavailable

Local Application Support is always the staging authority. Preferred-storage promotion may remain pending. Reconciliation copies to the external destination, verifies the copy, updates the manifest, and preserves the local source until completion is durable. No unrelated drive file is deleted or replaced.

### Multilingual dictation

1. The selected locale resolves before capture.
2. The Apple model is checked and installed if necessary.
3. The engine receives the explicit locale.
4. Cleanup selects an English, Spanish, French, or language-neutral deterministic profile.
5. Smart cleanup runs only when compatible and enabled.
6. Snippets and dictionary corrections remain Unicode- and NFC-safe.

### Selected-text Command Mode

1. A dedicated command binding captures the current selection and source app name.
2. The user dictates an instruction.
3. Foundation Models produces a local proposal.
4. A non-destructive review window shows original and proposed text.
5. The user explicitly replaces, copies, or cancels.

## Visual scope

The current shell, layout system, materials, typography, colors, spacing, animation language, and recorder aesthetic are protected.

Approved visible additions are limited to:

- status and actions on existing history rows;
- settings cards or rows for hands-free, microphones, languages, hotkeys, snippets, onboarding reset, and diagnostics;
- a first-run onboarding window using existing tokens and controls;
- a local Command Mode review window using existing panel styling;
- explicit progress, failure, compatibility, and recovery messages;
- architecture/OS compatibility labeling in shared artifacts.

Before each UI phase, capture the installed light and dark surfaces affected by that phase. After the phase, compare the same window, theme, state, and dimensions. Unapproved movement, color, typography, spacing, or animation changes must be restored.

## Intel strategy

The likely target is the 2020 Intel MacBook Air, which can run macOS 15 but not macOS 26. The 2014/2015 Mac is unsupported unless an unofficial operating system is used and remains experimental.

Intel work is a separate compatibility project:

1. Prototype an `x86_64`, macOS 15 command-line transcription probe using Apple's older compatible dictation engine.
2. Measure accuracy, latency, memory, and language availability on the actual 2020 Intel Air.
3. Confirm Accessibility insertion, microphone capture, permissions, and stable signing behavior.
4. If the probe passes, extract only portable modules into a legacy target.
5. Exclude Parakeet, Foundation Models cleanup, and Command Mode from the legacy edition.
6. Publish a separately labeled artifact. Never call it supported without exact-machine proof.

No universal lowest-common-denominator binary is planned.

## Phased delivery

### Phase 0: Baseline and contracts

- Capture installed-app light/dark baselines.
- Record current app version, signature, settings/history schemas, and smoke flows.
- Add test seams needed by the session pipeline without behavior change.
- Remove the Wispr Flow trigger/result path so comparison remains local.

### Phase 1: Durable recording sessions

- Add manifest state machine and local staging.
- Stream or append captured audio in order.
- Recover pending sessions on relaunch.
- Promote audio/history idempotently.

### Phase 2: History recovery and retranscription

- Add failed/recoverable history states.
- Add in-app playback.
- Add engine-selectable retry and preview.
- Confirm before replacing history.

### Phase 3: Hands-free dictation

- Add a separate binding and toggle lifecycle.
- Add Enter-to-finish and Escape-to-cancel while active.
- Preserve focus and exactly-once insertion.

### Phase 4: Audio input

- Add device catalog, persisted selection, test capture, and device-change recovery.
- Add permission and unavailable-device diagnostics.

### Phase 5: Multilingual transcription and cleanup

- Add language catalog, explicit selection, model state, and installation.
- Add English, Spanish, French, and neutral cleanup profiles.
- Verify Unicode dictionary and snippets across those languages.

### Phase 6: Hotkey registry

- Migrate existing choices into typed bindings.
- Add shortcut capture, gesture options, duplicate/reserved-risk validation, and restore defaults.

### Phase 7: Local snippets

- Add persistence, CRUD, exact-trigger expansion, and history visibility.

### Phase 8: Onboarding and diagnostics

- Add permission, hotkey, microphone, language/model, and test-dictation steps.
- Add reset and sanitized diagnostics export.

### Phase 9: Friend-share hardening

- Label Apple Silicon requirements.
- Add launch-time architecture/OS checks where the OS can execute the binary.
- Verify shared ZIP, installation guide, updater, migration, settings, permissions, and data preservation.

### Phase 10: Local Command Mode

- Add selected-text capture, dictated instruction, local transformation, review, replace/copy/cancel, and unavailable-device behavior.

### Phase 11: Intel compatibility investigation

- Build the macOS 15 `x86_64` probe.
- Exercise it on the actual target Mac.
- Proceed to a reduced legacy application only if the proof contract passes.

## Throughput checkpoint

### Blocking first steps

Phase 0 and the durable session data shape must land before recovery, retranscription, or hands-free behavior. Language selection must land before localized cleanup. The hotkey registry must land before arbitrary shortcut recording.

### Independent workstreams

After the durable session and settings-schema gates, audio input, language catalog, snippets, diagnostics, and friend-share tooling touch mostly disjoint modules. Current collaboration policy does not authorize subagents, so implementation remains serialized in this task unless the user later explicitly requests delegation.

### Shared mutable state

`DictationController`, `Settings`, `RunLog`, and external-drive files are current shared-state concentrations. New modules separate session, snippet, language, device, and diagnostic state before writes are serialized. Main-actor state remains UI-facing; filesystem and model work stays off the main actor.

### Smallest safe decomposition

Each phase introduces one primary deep module plus its direct adapter/UI consumer and tests. Dictionary, update, permission, and design-system modules are changed only when the phase's acceptance criteria require it.

## Acceptance ledger

| Outcome | Target surface | Required proof | Status |
| --- | --- | --- | --- |
| Failed or interrupted speech remains recoverable | Installed modern app | Forced engine failure and relaunch preserve playable audio and one recoverable row | Pending |
| Audio paths never reference unconfirmed writes | Storage and history | Simulated write/copy failures plus installed drive-disconnect exercise | Pending |
| History audio plays and retranscribes without insertion | Installed history | Play, retry with each installed engine, preview, confirm/cancel | Pending |
| Hands-free recording works exactly once | Installed app and focused target app | Toggle, Enter, Escape, repeat press, long utterance, no duplicate paste | Pending |
| Microphone choice and recovery work | Installed Settings and capture | System default, selected device, unplug/change, denial, reconnect | Pending |
| Spanish and French dictation are explicit and safe | Installed Settings and dictation | Model selection/install, sample corpus, localized/neutral cleanup, Unicode corrections | Pending |
| Hotkeys are configurable without common conflicts | Installed Settings and target apps | Capture, duplicate detection, gesture timing, international Option-key checks | Pending |
| Snippets expand locally and predictably | Installed app | Exact whole-utterance, multiline, disabled, Unicode, dictionary ordering | Pending |
| Friends can complete setup without operator guidance | Fresh installed copy | Permissions through first successful dictation and rerunnable setup | Pending |
| Diagnostics reveal no speech content | Exported diagnostics artifact | Schema/content audit and installed export | Pending |
| Friend artifacts install and update without data loss | Shared ZIP and installed app | Clean install, update, rollback-safe failure, settings/history preservation | Pending |
| Command Mode transforms selected text locally and asks before replacement | Installed app and target app | Replace, copy, cancel, unavailable model, no network fallback | Pending |
| Intel support is accurately scoped | 2020 Intel MacBook Air | Native `x86_64` probe and, if successful, reduced app smoke matrix | Pending; exact hardware required |
| Current dictionary behavior remains identical | macOS tests and shared vectors | `swift test --filter VectorTests` and complete `make test` | Pending |
| Existing shell remains visually stable | Installed light/dark app | Before/after surface matrix for every affected window/state | Pending |
| No private content leaves the Mac | Runtime and source | Wispr path removed; network-path audit confirms only update/model retrieval; offline installed flows pass | Pending |

## Test strategy

Every behavior change follows RED, GREEN, REFACTOR. Production code is not written until the relevant test fails for the expected reason.

Static verification:

```bash
make test
```

Focused suites will cover:

- session-state transitions and manifest decoding;
- idempotent recovery and promotion;
- staged-audio write and copy failure;
- history retry without injection;
- hands-free transition and exactly-once finish/cancel;
- language resolution, missing models, and no silent English fallback;
- English, Spanish, French, and neutral cleanup profiles;
- hotkey conflict and gesture policy;
- snippet ordering and Unicode normalization;
- onboarding state and reset;
- diagnostic redaction;
- Command Mode review and confirmation;
- compatibility checks and schema migration.

Exact-surface verification:

- development app bundle;
- staged app bundle;
- `/Applications/Murmure.app` installed copy;
- focused TextEdit, Notes, browser text fields, and a code editor;
- light and dark appearance;
- external drive connected, disconnected at launch, and disconnected during promotion;
- microphone permission allowed and denied;
- Apple and Parakeet engines where supported;
- English, Spanish, and French sample recordings;
- clean friend-style installation and update;
- actual Intel hardware for any Intel claim.

## Documentation and migration

- Settings snapshots gain schema-aware optional fields with safe defaults.
- Existing history JSONL remains decodable.
- Pending-session manifests use an explicit schema version.
- Existing audio and correction records remain valid.
- `shared/dictionary-test-vectors.json` changes only if correction behavior intentionally changes on both platforms. This program does not currently require such a change.
- Friend installation notes document Apple Silicon/macOS requirements, permissions, local storage, recovery, languages, model downloads, and the unnotarized first-launch process.

## Definition of complete

The goal is complete only when every non-Intel acceptance row is implemented and verified on the exact modern installed surface, protected visuals remain stable except for approved additions, all macOS tests pass, and privacy/offline behavior is proven. Intel remains explicitly pending or blocked until the actual target hardware is available; it is never inferred from compilation alone.
