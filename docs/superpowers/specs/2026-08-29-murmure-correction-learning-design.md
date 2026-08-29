# Murmure correction learning design

## Goal

Let a user correct a saved dictation once, keep the corrected history, and teach Murmure a
constrained future rewrite when the edit can be represented safely. Typed text is authoritative.
Voice is an optional way to fill the editable correction field and never saves by itself.

## User flow

1. A history row exposes a Correct action.
2. The correction sheet shows the original text under "Murmure heard" and an editable
   "I meant" field.
3. Play original replays the retained CAF file when one exists.
4. Dictate records a fresh local correction attempt. Stop returns the transcript to the
   editable field. The user can type over any remaining mistake.
5. "Remember for future dictations" is on by default. The sheet previews the exact learned
   phrase when a safe rule exists.
6. Save correction updates the history item. When remembering is on and the learner produced
   a safe rule, the same action upserts that rule into the dictionary.

There is one save boundary. Voice completion, sheet dismissal, and audio playback never edit
history or the dictionary.

## Data model

`CorrectionRuleSuggestion` is the pure learner output. It stores `hear` and `write` snapshots.
Dictionary entry UUIDs are not persisted in correction history because parsing `dictionary.txt`
recreates them.

`TranscriptCorrectionRecord` is stored on `DictationRun`:

- `heardText` preserves the first text the user corrected.
- `intendedText` is the latest saved correction.
- `correctedAt` records the latest save.
- `inputMethod` is `typed` or `voiceAssisted`.
- `rememberedRule` snapshots the learned `hear` and `write` pair, or is absent for history-only
  corrections.
- `pendingRule` is a durable handoff journal. It exists only after corrected history is confirmed
  and before both the dictionary write and final remembered metadata are confirmed.

`DictationRun.text` remains the effective text shown, searched, copied, and rendered in the
dashboard. Older JSONL rows decode with no correction record.

## Safe learner

`CorrectionLearner.plan(heard:intended:)` is pure and deterministic:

1. Trim outer whitespace and normalize both strings to NFC.
2. Tokenize Unicode words while retaining source ranges.
3. Remove the longest identical word prefix and suffix.
4. Reject blank intended text, insertion-only or deletion-only edits, punctuation-only edits,
   multiline or dictionary-syntax text, and edits wider than the configured word or character
   caps.
5. Do not create a global one-word rewrite. Add equal neighboring context until the heard side
   contains at least two words.
6. Validate the candidate by applying a new `DictionaryCorrector` containing only that rule.
   The candidate is safe only when it transforms the complete heard transcript into the complete
   intended transcript exactly.

Examples:

- `Everything is a lie.` to `Everything is a line.` learns `a lie -> a line`.
- `I spoke to banana yesterday.` to `I spoke to Mariana yesterday.` learns
  `to banana -> to Mariana`.
- `lie and lie` to `line and lie` expands to `lie and -> line and` so the second occurrence
  remains unchanged.
- A punctuation-only edit updates history but creates no dictionary rule.

Upsert is idempotent. The same normalized trigger replaces an older conflicting correction,
reenables a disabled correction, and moves the learned entry to the front of the dictionary so
it remains inside the existing 40-phrase engine-bias limit.

## Voice isolation

`CorrectionVoiceController` owns a separate `AudioCapture` and the selected local
`TranscriptionEngine`. It uses the same ordered buffer-drain and finalize sequence as normal
dictation, but it has no access to text injection, run logging, comparison mode, Wispr Flow, or
dictionary persistence.

The main controller suspends its global hotkey while the correction sheet is visible. This
also blocks button-driven recording in every app window, preventing two audio engines from
starting at once. Suspension and resumption are idempotent. Original playback stops before voice
capture. Closing the sheet cancels any correction recording and re-arms the hotkey.

## Storage and privacy

The corrected run remains in the existing `runs.jsonl`, and learned rules remain in
`dictionary.txt`. Both already resolve through `MurmureDataStore` to
`/Volumes/Extreme Pro/Murmure Data` on this Mac. The original history audio path is retained.
Correction voice attempts are transient and are discarded unless their resulting text is saved.
No hosted API, account, or remote service is added.

History append/rewrite operations, dashboard renders, and dictionary snapshots are each serialized
so an older write cannot finish last. Save first persists corrected history with any learned rule
marked pending, then confirms `dictionary.txt`, then promotes the pending rule to remembered
metadata. Launch hydration idempotently repairs any pending handoff. A transient dictionary read
failure blocks mutation rather than treating an existing file as empty.

## Visual constraints

The existing design is locked. The new sheet uses only `DS` colors, fonts, spacing, radii,
motion, and new size tokens. Red appears only while correction voice recording is active.
Amber and green remain instrumentation colors. The layout, navigation, history cards, and other
screens do not change.

## Acceptance criteria

- Correcting a run changes that run's displayed, searchable, copyable, and dashboard text.
- The original heard text and original audio remain available.
- One Save updates history and remembers a safe rule by default.
- Repeating Save does not create duplicate or conflicting dictionary rules.
- A learned rule fixes the same future mishearing through the existing dictionary pass.
- Voice can fill the draft, but only Save persists anything.
- Cancel and voice failure preserve the pre-voice typed draft and change no stored data.
- Existing runs decode, dictionary vectors remain unchanged, and all Swift tests pass.
- The signed bundle builds, installs at `/Applications/Murmure.app`, launches, and exposes the
  correction workflow on the installed surface.
