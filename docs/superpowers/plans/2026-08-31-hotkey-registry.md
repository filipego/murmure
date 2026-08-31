# Typed Hotkey Registry Implementation Plan

## Outcome

Replace the three-value shortcut settings with durable typed bindings while preserving every
working current choice. Add safe custom shortcut capture, hold/toggle/double-tap-and-hold
gesture policy, conflict and reserved-shortcut validation, and restore defaults.

## Constraints

- Keep the existing Settings shell and field-recorder design unchanged.
- Preserve `fn`, Right Option, and Right Command behavior and migration.
- Never swallow unrelated keys or a modifier release that Murmure did not own.
- Keep `fn` observable rather than consumed so system `fn` combinations still work.
- Warn about international-layout and system-reserved risks before persistence.
- Suspend the global event tap while a Settings shortcut recorder owns keyboard input.
- Do not synthesize keyboard events during verification.

## Task 1: Pure binding domain

1. Add red tests for legacy preset migration, stable identifiers, Codable round trips,
   duplicate detection, unsafe bare keys, reserved macOS shortcuts, and international-layout
   warnings.
2. Add `HotkeyBinding`, `HotkeyGesture`, `EventConsumptionPolicy`, `ModifierSide`, and typed
   validation outcomes.
3. Keep framework flag constants at the adapter boundary; the domain stores plain values.

## Task 2: Gesture policy

1. Add red tests for hold start/finish, toggle start/finish, repeat suppression, and the
   double-tap-and-hold timing window.
2. Implement a pure `HotkeyGesturePolicy` state machine.
3. Reset the policy on cancellation, failure, deactivation, and completed sessions.

## Task 3: Event-tap registry

1. Teach the event adapter to match both modifier-only presets and key-plus-modifier chords.
2. Observe key-up for chord release without consuming unrelated target-app events.
3. Route semantic press/release edges through the gesture policy.
4. Preserve hands-free Enter/Escape scope and its exactly-once toggle lifecycle.

## Task 4: Backward-compatible settings

1. Add optional typed bindings to the local and external settings snapshot.
2. Resolve old string keys into typed defaults when new fields are absent.
3. Persist typed bindings and keep the old keys as a downgrade-compatible mirror.
4. Normalize duplicates deterministically without losing both actions.
5. Add restore-defaults behavior without applying it automatically to existing users.

## Task 5: Shortcut capture and Settings UI

1. Add a focused local recorder sheet that captures the next modifier-only key or chord.
2. Show the binding label, gesture choice, and validation result in the existing Push to talk
   card.
3. Reject invalid or duplicate bindings without changing the active registry.
4. Explain risky-but-allowed choices and require a second confirmation action.
5. Add Restore defaults in the same card; do not change unrelated layout or styling.

## Task 6: Verification

1. Run focused and full `make test` gates with no warnings.
2. Install the exact signed app with `make install`.
3. Verify legacy settings migration, recorder cancellation, a non-reserved custom chord,
   duplicate rejection, gesture persistence, and restore defaults on the installed surface.
4. Verify unrelated TextEdit content remains exact and ordinary keys are not swallowed.
5. Record any physical modifier-only limitation that Computer Use cannot exercise.

