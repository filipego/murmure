# Local selected-text Command Mode plan

## Outcome

Holding a dedicated shortcut over selected text records a spoken editing instruction. Apple's
on-device Foundation Model creates a proposal, and Murmure shows the original and proposal in a
review window. Nothing is replaced until the user explicitly chooses Replace; Copy and Cancel
remain available.

## Safety contract

- Selected text and the instruction are never persisted, logged, included in diagnostics, or
  sent to a network service.
- There is no cloud or deterministic fallback for transformation. An unavailable Apple
  Intelligence model produces a clear local-only limitation.
- Replace targets the exact captured accessibility element and proceeds only while its selected
  text still equals the captured original. A changed or unavailable target refuses replacement.
- Opening the review window may take focus; replacement never uses simulated paste into the
  currently focused app. Copy is the safe fallback.
- Ordinary dictation and Command Mode cannot record at the same time.

## Implementation slices

1. Add failing tests for request/review state, transformation validation, safe replacement
   policy, three-way hotkey conflicts, and the Command Mode event route.
2. Add selected-text capture and guarded replacement through Accessibility.
3. Add the Foundation Models transformer with bounded output and explicit availability/error
   behavior.
4. Add an instruction-recording controller using the existing microphone selection and local
   speech-engine adapters without history persistence or text injection.
5. Extend typed shortcut settings and the event router with an enableable Command Mode binding.
6. Add the protected-style review window and Settings controls.
7. Run the full suite, install the signed app, and verify failure, copy, cancel, and guarded
   replacement on the exact installed surface without altering existing text unexpectedly.
