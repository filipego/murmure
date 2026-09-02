# Live Text Insertion Design

## Goal

Add an opt-in dictation behavior that writes Apple Speech transcription into the focused text field while the user is speaking. Preserve the current behavior, which inserts one cleaned result after the user finishes, as the default.

## User-facing behavior

Settings > Dictation adds a picker named “When should Murmure type?” with two values:

1. “After I finish speaking” keeps the current behavior and remains the default.
2. “While I’m speaking” streams Apple transcription into the verified destination field.

The live option is available only when Apple is the resolved speech engine. Automatic spoken-language detection resolves to Parakeet, so selecting Automatic or Parakeet keeps after-finish insertion and explains why live typing is unavailable. Compare Mode and Command Mode never type live.

English, French, and Spanish receive complete localized labels, explanations, status text, and accessibility copy through the existing localization catalog.

## Approaches considered

### Append only finalized speech segments

Insert only segments that Apple marks final. This is safe and simple, but it feels delayed, cannot show the recognizer’s most recent words, and makes whole-utterance cleanup, snippets, and dictionary corrections difficult to reconcile.

### Replace an owned range in the destination field

Capture the focused accessibility element and its selected range when dictation begins. Each live snapshot replaces only the exact range Murmure previously inserted. On release, the same owned range is replaced with the cleaned, snippet-expanded, dictionary-corrected final result. This provides the requested experience without weakening final-text behavior.

This is the selected approach.

### Simulate deletion and retyping with keyboard events

Send Backspace or selection keystrokes before every revised partial. This works in more applications but cannot prove which text is being deleted after a caret move, mouse click, focus change, or target-app edit. It is rejected because it could destroy user text.

## Data model

`TextInsertionTiming` is a persisted, codable setting with `afterSpeaking` and `whileSpeaking` cases. Missing persisted values decode to `afterSpeaking`.

`TranscriptionChunk` continues to carry the full transcript snapshot. Apple’s volatile snapshots drive live replacement; the stream’s final snapshot remains the source for post-processing and durable history.

`LiveTextInsertionSession` is a focused, main-actor-owned state machine:

- `inactive` has no captured destination.
- `ready` owns a target accessibility element, application identity, original selection range, and original selected text.
- `rendering` additionally owns the exact rendered text and its expected range.
- `abandoned` means verification failed. It performs no more live mutations and allows normal after-finish insertion.
- `completed` means the verified owned range contains the final processed text.

Illegal transitions are rejected. Only the session can mutate its owned range.

## Runtime flow

1. At dictation start, resolve the engine, language, and insertion timing into the immutable per-utterance configuration.
2. When live typing is requested and Apple is resolved, capture the currently focused accessibility element and selection without changing it.
3. For each Apple transcript snapshot, verify that the same application and element remain focused, the selection is at Murmure’s expected endpoint, and the previously rendered range still contains exactly Murmure’s prior text.
4. Replace only the verified owned range with the latest full snapshot. Coalesce rapid updates so an older snapshot can never overwrite a newer one.
5. At release, run the existing cleanup, snippet, and dictionary pipeline over the final transcript.
6. Replace the verified owned range with the processed final result. Persist history and audio through the existing recording-session coordinator.
7. If any live verification fails, mark the live session abandoned and stop mutating the destination. At completion, remove any still-verifiable live text before using the existing one-shot final insertion. If safe removal cannot be proven, keep the owned text, save the final result to history, and surface a recoverable status instead of risking unrelated content.

## Safety rules

- Never select, delete, or replace a range unless its current text exactly equals the text Murmure recorded as owned.
- Never continue live updates after the focused application, focused element, or expected caret changes.
- Never use unverified Backspace or arrow-key editing.
- Cancellation restores the original selected text only when the owned range is still verifiable.
- An empty or failed transcription does not leave temporary live text behind when verified rollback is possible.
- Existing after-finish insertion retains its Accessibility-first and pasteboard fallback behavior.
- Live typing does not change audio capture, session durability, history, retry, recovery, Compare Mode, or Command Mode.

## Components

- `Settings.swift` owns `TextInsertionTiming`, persistence, migration, and the per-utterance value.
- `SettingsWindow.swift` presents the localized picker and availability explanation inside the existing Dictation category.
- `LiveTextInsertionSession.swift` owns verified target capture, owned-range replacement, rollback, abandonment, and completion.
- `DictationController.swift` creates the session, sends snapshots, finalizes processed text, and preserves the existing fallback path.
- `TextInjector.swift` remains the one-shot insertion adapter. Shared low-level accessibility helpers may move to a focused internal utility when both insertion paths need them.
- `catalog.tsv` contains all English, French, and Spanish prose.

## Test seams

The approved public seams are:

1. Settings snapshot decoding and persistence. Missing timing defaults to `afterSpeaking`; both values round-trip.
2. A pure owned-range policy. Matching target, caret, and text permits replacement; any mismatch abandons without a mutation command.
3. Dictation completion routing. Successful live ownership finalizes the owned range once; unavailable or abandoned live ownership uses the existing final-insertion path; Compare Mode never inserts.
4. Localization catalog coverage for every new visible string in English, French, and Spanish.
5. Installed-app interaction. The setting appears in Settings > Dictation, after-finish remains unchanged, Apple live typing updates a real text field, moving the caret stops live mutation safely, and the final cleaned result is correct.

Framework accessibility calls stay behind an adapter and are verified in the installed app rather than mocked as if macOS behavior were guaranteed.

## Visual scope

The authorized visible change is one picker and one short explanatory/status line inside Settings > Dictation. Existing category navigation, spacing, typography, colors, controls, and all other settings pages remain protected. The new row uses existing components and design tokens.

## Compatibility and cost

The feature uses Apple’s on-device SpeechAnalyzer and macOS Accessibility APIs. It introduces no cloud service, subscription, paid API, or new dependency. Parakeet remains batch-only in this scope. Streaming Parakeet through FluidAudio’s sliding-window recognizer is a separate future project.

## Acceptance criteria

- Existing installations default to “After I finish speaking.”
- Apple dictation with an explicit spoken language can type live into a verified destination.
- The final visible text matches the existing cleanup, snippet, and dictionary pipeline output.
- Focus, element, caret, or owned-text changes stop live mutation without deleting unrelated text.
- Automatic language, Parakeet, Compare Mode, and Command Mode never attempt live insertion.
- Settings copy is complete and understandable in English, French, and Spanish.
- All Swift tests pass with new red-to-green coverage at the approved seams.
- `make` succeeds, the app is installed with `make install`, and the real installed app passes the live-typing and protected-UI scenarios.
