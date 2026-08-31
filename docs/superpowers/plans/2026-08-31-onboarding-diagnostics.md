# First-run onboarding and sanitized diagnostics plan

## Goal

Let a friend reach a successful local dictation without operator guidance, and let them export enough environment information to troubleshoot setup without exposing anything they said or saved.

## Contracts

- `OnboardingState` persists only completion and the last acknowledged setup step. It derives permission/model/device readiness from production providers each time it renders.
- Setup is rerunnable from Settings. Reset clears onboarding progress only; it never changes permissions, settings, history, audio, dictionary, or snippets.
- Steps use the real modules in this order: local-privacy explanation, microphone permission, Accessibility permission, shortcut/gesture, microphone selection and test, language/model, test dictation, completion.
- A user can return to an earlier step. Completion requires both permissions and one acknowledged test dictation; it is idempotent.
- `DiagnosticsSnapshot` contains app version/build, macOS version, architecture, selected microphone label, engine, language, local model state, permission states, storage state, and the last operational failure if present.
- Diagnostics never contain transcript text, selected text, correction/dictionary/snippet content, audio, speech-derived filenames, UUIDs, or unrelated filesystem paths.
- Export is pretty-printed JSON selected through a native save panel. Copy/export uses the same collector output.

## Work slices

1. Add failing tests for onboarding transitions, completion/reset persistence, permission gating, idempotence, diagnostics schema, and forbidden-content audit.
2. Implement the pure onboarding policy, small persisted store, and typed diagnostics collector with injectable providers.
3. Add a first-run SwiftUI `Window` using existing design tokens. Launch it from the main scene when incomplete and expose “Run setup again” from Settings.
4. Wire permission requests, settings-backed shortcut/language controls, microphone test, and a test-dictation step to existing production modules. No parallel capture implementation.
5. Add a Settings diagnostics card with preview, copy, and native JSON export.
6. Run the full suite, install the signed app, verify reset/relaunch/rerun and redaction on the exact surface, then restore onboarding completion and existing user settings.

## Safety and visual scope

- No cloud, account, telemetry, or transcript logging.
- No automatic System Settings changes; permission actions use the existing OS flows.
- Existing shell layout remains unchanged except for the approved Settings cards and onboarding window.
