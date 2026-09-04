# Command Snippets and Fast Live Text Design

## Goal

Make deliberate snippet commands and live dictation behave predictably. Saying `Murmure add, my address` invokes the `my address` snippet. The existing bare `my address` trigger remains supported. During ordinary dictation, preliminary text should appear as quickly as Apple's local recognizer permits. Releasing the shortcut must replace Murmure's preview with exactly one cleaned final result.

## Spoken command

`Murmure add` is the fixed command prefix. Matching is case-insensitive, Unicode-normalized, whitespace-tolerant, and tolerant of ordinary punctuation between the prefix and trigger. The prefix is removed before exact whole-trigger matching. Extra words before or after the trigger do not match. A bare exact trigger continues to match for compatibility.

## Streaming behavior

Apple Speech uses volatile and fast results for responsive preliminary text. Preliminary text may be less accurate. It remains temporary and owned by the active live insertion session. The existing cleanup, snippet expansion, dictionary corrections, and persistence pipeline produces the authoritative result after release.

## Final replacement

The live insertion session must distinguish an unobserved posted paste from lost ownership. It should retry observation for the bounded paste window and adopt the inserted range only when the destination, selection, and text prove ownership. Once ownership is proven, finalization replaces the complete preview. If ownership cannot be proven, the recording and final text remain in History without appending a duplicate.

## Verification

- Unit tests cover prefixed and bare snippet triggers, punctuation, and extra-word rejection.
- Unit tests cover delayed live-paste observation followed by safe final replacement.
- Engine configuration tests require Apple's fast and volatile result options.
- The full macOS suite passes with `make test`.
- The installed app is checked in a real text field. A human speech pass remains required when synthetic audio cannot reach the selected microphone.

## Constraints

- Remain local and free.
- Preserve the current visual design and settings.
- Preserve final accuracy and correction ordering.
- Never expose snippet replacement contents in logs or tests.
- Leave `docs/research/` untouched.
