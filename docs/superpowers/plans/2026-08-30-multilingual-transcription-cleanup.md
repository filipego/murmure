# Multilingual Transcription and Cleanup Implementation Plan

**Goal:** Make Murmure's language choice explicit and durable, support English, Spanish,
and French end to end on both local speech engines, and never silently substitute English.

## Product contract

- `System default` resolves to the closest locale supported by the selected engine.
- Explicit English, Spanish, and French choices are passed to Apple Speech and used as
  Parakeet v3 language hints.
- An unsupported Apple locale stops before capture with a clear error. It never falls back
  to `en-US`.
- Apple's speech asset state is shown as installed or requiring a one-time system-managed
  download. The asset is installed by the existing Speech framework request when dictation
  begins.
- Parakeet continues to use its one downloaded multilingual v3 model. The selected language
  is a decoder hint; `System default` leaves Parakeet in automatic multilingual mode.
- Deterministic cleanup has English, Spanish, and French profiles. Every other language uses
  language-neutral Unicode normalization and whitespace cleanup only.
- Smart cleanup is enabled only when the on-device Foundation Model reports that it supports
  the selected locale. Otherwise Settings explains that deterministic cleanup will be used.
- The selected language is snapshotted at the beginning of each recording and stored in its
  session manifest, so a mid-recording Settings change cannot alter the engine or formatter.

## Task 1: Language domain and resolution

1. Add failing tests for stable locale identifiers, engine capability, system-default
   resolution, explicit resolution, unsupported resolution, and Parakeet hints.
2. Extend `TranscriptionLanguageSelection` with hashing and stable helpers.
3. Add a pure language policy with the user-facing English, Spanish, and French choices.
4. Add an Apple Speech catalog adapter that obtains supported and installed locales from
   `SpeechTranscriber` without blocking launch.
5. Make `AppleSpeechEngine` reject unsupported locales and remove the `en-US` fallback.
6. Pass the resolved language hint into `ParakeetEngine`.

## Task 2: Durable Settings and session snapshots

1. Add backward-compatibility tests proving old settings decode as `System default`.
2. Persist the optional language selection in UserDefaults and the external settings JSON.
3. Snapshot engine, language, and formatter configuration when recording begins.
4. Store the selected language in live and comparison recording metadata.

## Task 3: Language-aware deterministic cleanup

1. Add red tests for English, Spanish, French, unknown-language neutral behavior, accents,
   composed/decomposed Unicode, and spoken paragraph/line commands.
2. Introduce immutable cleanup profiles for English, Spanish, French, and neutral behavior.
3. Normalize input and output to NFC.
4. Apply filler removal and spoken punctuation only for the selected supported profile.
5. Keep unknown-language cleanup strictly neutral: Unicode and whitespace normalization,
   with no English capitalization, punctuation, or filler assumptions.

## Task 4: Smart cleanup compatibility

1. Add a locale-aware compatibility seam around `SystemLanguageModel.supportsLocale`.
2. Give `FoundationModelFormatter` the same immutable cleanup profile and locale as its
   deterministic fallback.
3. Instruct the model to preserve the selected language and never translate.
4. Fall back deterministically on unsupported language, timeout, rejection, or generation
   failure.

## Task 5: Settings UI

1. Add a language picker to the existing Transcription card.
2. Show Apple language asset status and the one-time download behavior.
3. Explain Parakeet automatic mode versus an explicit language hint.
4. Disable smart cleanup when the selected locale is unsupported and display the reason.
5. Use only existing design-system tokens; do not change the surrounding shell.

## Task 6: Verification

1. Run focused tests after every red/green slice and the full `make test` suite at the end.
2. Build and install with `make install` so the exact signed `/Applications/Murmure.app`
   surface is tested.
3. Verify the installed Settings picker, status copy, persistence across relaunch, and
   English/Spanish/French selections in the in-app Browser/Computer Use surface.
4. Perform short local dictation smoke tests where input can be safely controlled; record
   any physical-accent or model-download case that cannot be exercised honestly.
5. Confirm the TextEdit sentinel remains exactly unchanged and capture evidence under
   `.impeccable/review/multilingual/`.

