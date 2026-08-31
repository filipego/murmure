# Hands-Free Dictation Implementation Plan

Date: 2026-08-30

## Outcome

Add an opt-in, local hands-free trigger that starts on one dedicated modifier press, finishes on the same modifier or Enter, and cancels on Escape. The focused application must remain focused, control keystrokes must be consumed only while a hands-free session is active, and every successful session must use the existing durable recording and exactly-once insertion path.

## Constraints

- Preserve the existing hold-to-talk and Record button behavior.
- Keep hands-free disabled by default and require a binding distinct from push-to-talk.
- Reuse the existing modifier choices in this phase; arbitrary shortcut capture belongs to the later hotkey-registry phase.
- Do not activate Murmure when global controls are used.
- Observe and consume Enter, keypad Enter, and Escape only during an active hands-free session.
- Do not change design-system tokens or the established visual shell.
- Keep settings JSON backward-compatible with snapshots that predate hands-free fields.

## Deep module boundary

`HandsFreeGesturePolicy` owns the toggle lifecycle as a pure value type. It converts semantic events into `start`, `finish`, `cancel`, or `ignore` commands and prevents duplicate finish/cancel actions. `HotkeyMonitor` remains the AppKit adapter: it translates modifier and key events into semantic callbacks and decides whether an event is consumed. `DictationController` orchestrates policy commands through the existing recording pipeline.

## Tasks

### 1. Lock the current surface

- Capture the installed Settings window before adding controls.
- Record the exact app version, executable hash, architecture, and affected window dimensions.

### 2. Specify the gesture lifecycle test-first

- Add failing tests for start, same-binding finish, Enter finish, Escape cancel, ignored inactive controls, and repeated events during finishing.
- Implement `HandsFreeGesturePolicy` in the platform-neutral session core.
- Add key-classification tests for Return, keypad Enter, Escape, and unrelated keys.

### 3. Persist a distinct opt-in binding

- Add `handsFreeEnabled` and `handsFreeKey` settings with backward-compatible decoding and UserDefaults fallback.
- Centralize paired binding updates so push-to-talk and hands-free cannot persist the same modifier.
- Add tests for conflict resolution and legacy snapshots.

### 4. Extend the global event adapter

- Track hold-to-talk and hands-free modifier edges independently.
- Route a hands-free modifier press as a toggle and do not treat its release as a finish.
- Include key-down events in the tap, but route/consume Enter and Escape only while the controller reports an active hands-free session.
- Preserve fn pass-through behavior and existing tap re-arming.

### 5. Integrate the durable recording lifecycle

- Start hands-free sessions with `.handsFree(bindingID:)`.
- Finish through the existing staging, formatting, history, and one-time insertion tail.
- Cancel through the existing durable-session cancellation path without insertion.
- Reset gesture state on completion, failure, deactivation, or teardown.
- Keep hold-to-talk release and the Record button independent.

### 6. Add the approved settings controls

- Add a hands-free toggle and dedicated-key picker to the existing Push to talk settings card using existing tokens and controls.
- Filter the picker to bindings distinct from push-to-talk and re-arm the event tap after changes.
- Add concise behavior text explaining toggle, Enter, and Escape.

### 7. Verify source and installed behavior

- Run focused gesture/settings tests, `make test`, and dictionary vector tests.
- Build and install with `make app` and `make install`.
- Verify the installed Settings surface against its baseline.
- With TextEdit focused, verify start/finish by binding, Enter finish without newline, Escape cancel without insertion, repeated finish without duplicate paste, and focus preservation.
- Record exact-surface evidence and any hardware-dependent limits without overstating them.

## Acceptance

- Hold-to-talk behavior remains unchanged.
- Hands-free is disabled by default and its binding cannot conflict with push-to-talk.
- One hands-free activation produces at most one inserted transcript.
- Enter and Escape pass through normally when hands-free is inactive.
- Enter finishes without adding a newline; Escape cancels without pasting.
- Installed verification shows the focused target remains focused throughout activation and completion.
- All source tests and deterministic dictionary vectors pass.
