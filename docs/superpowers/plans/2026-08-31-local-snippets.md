# Local snippets implementation plan

## Goal

Add predictable, entirely local snippet expansion without changing the existing dictionary contract or shell. A snippet replaces a complete cleaned utterance before dictionary corrections, persists with the rest of Murmure's local data, and remains visible in history.

## Contract

- `SnippetEntry` is Codable, ordered, enabled/disabled, and identified by UUID.
- `SnippetExpander` is pure. It NFC-normalizes and trims the utterance and trigger, compares the complete utterance case-insensitively, and replaces only one exact whole-utterance match. It never performs substring replacement.
- Multiline and Unicode replacements are supported. Empty triggers and replacements are rejected. Duplicate normalized triggers are rejected.
- Pipeline order is cleanup → snippet expansion → dictionary correction.
- History records the applied snippet's stable ID and trigger without duplicating its replacement text as metadata.
- Existing settings, dictionary files, and history remain decodable.

## Work slices

1. Add failing tests for exact matching, non-matching prose, disabled entries, ordering, Unicode, multiline output, validation, and Codable compatibility.
2. Implement the pure snippet domain and expander.
3. Add `SnippetStore` with atomic local persistence, deferred hydration, ordered CRUD, and a testable persistence seam. Store it at the Murmure data root.
4. Insert the expander into live dictation and archived retranscription before dictionary correction. Add optional applied-snippet metadata to history.
5. Add a Settings card and native editor sheet using only existing design tokens. Support add, edit, enable/disable, delete, and clear validation messages.
6. Run the full suite, package/install the signed app, verify CRUD and persistence on the installed Settings surface, and confirm the TextEdit sentinel is unchanged.

## Safety and scope

- No network, account, cloud, telemetry, wake word, or visual-shell redesign.
- No changes to `shared/dictionary-test-vectors.json`; dictionary correction behavior remains authoritative and runs after snippets.
- Existing user data is preserved. Destructive deletion is limited to the exact selected snippet and requires an explicit UI action.
