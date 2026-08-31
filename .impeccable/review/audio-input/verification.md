# Audio Input Selection and Recovery Verification

Date: 2026-08-30

## Installed artifact

- App: `/Applications/Murmure.app`
- Bundle identifier: `ai.pivotstudio.murmur-youtube`
- Version: `0.1.12` (12)
- Executable SHA-256: `521b210d5f498698732cd80b64280e1503bec17284a81fa119a0b48eba34df8d`
- Architecture: `arm64`
- Signed with the stable local signing identity and installed through `make install`.

## Source proof

- Phase 4 focused suites passed for:
  - system-default, explicit, fallback, reconnect, unavailable, and Codable selection policy;
  - live CoreAudio input enumeration with stable unique UIDs;
  - permission-gated level-only test capture;
  - benign/restart/fail audio-configuration change classification.
- Final `make test`: 16 XCTest tests and 163 Swift Testing tests passed; one pre-existing stable-signed-fixture test skipped because the fixture is unavailable.
- Shared dictionary vectors passed inside the full suite.
- No compile warnings were emitted.

## Exact installed surface

- `settings-idle.jpeg`, 1020 × 768, shows the approved Microphone card in the existing Settings stack.
- `microphone-test-active.jpeg`, 1020 × 768, shows the existing field-recorder VU meter responding during live capture.
- The card exposes System default plus four live explicit inputs on this Mac:
  - soundcore Q20i · Bluetooth · Default;
  - CADefaultDeviceAggregate-8913-0 · Aggregate;
  - External Microphone · Built-in;
  - Filipe Valente’s iPhone Microphone · Continuity.
- The original layout, sidebar, card styling, typography, colors, and materials remain unchanged outside the approved card. One `DS.Size` token was added for the meter height; no existing token changed.

## Installed functional proof

- System default resolved visibly to `soundcore Q20i · Bluetooth`.
- The first installed test exposed a false disconnect: Bluetooth emitted a benign AVAudioEngine configuration update immediately after opening. The implementation was corrected to compare current device ID and alive state, ignore a benign running update, restart a benign paused engine, and fail only on a dead or different device.
- After reinstalling that correction, the level-only test remained active, displayed `Listening to soundcore Q20i. Test audio is not saved.`, and the VU needle visibly responded.
- The same soundcore input was selected explicitly and the installed level-only test remained active there too.
- The prior System default preference was restored afterward and persisted as `{"systemDefault":{}}` in local settings.
- Test capture produced no transcript/history mutation:
  - `runs.jsonl` SHA-256 remained `cae41f4797c22028dc187d89cf45d3f889e441211dc7ac3113471f8f14e95198`;
  - retained history CAF count remained 9;
  - durable recording-session manifest count remained 1.

## Recovery and privacy boundary

- Unit policy proves a missing explicit UID falls back to the current default without rewriting the explicit selection, and the same saved UID resolves explicitly again after reconnection.
- The live catalog observes device-list and default-input changes; active capture validates current device ID and alive state on AVAudioEngine configuration changes.
- No attached microphone was physically unplugged during this run, so unplug/reconnect is not claimed as an installed hardware exercise.
- CoreAudio UIDs and display names remain local. Test samples are discarded in memory and never enter recording sessions, history, audio archives, transcription, or a network path.
