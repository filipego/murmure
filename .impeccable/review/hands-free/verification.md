# Hands-Free Dictation Verification

Date: 2026-08-30

## Installed artifact

- App: `/Applications/Murmure.app`
- Bundle identifier: `ai.pivotstudio.murmur-youtube`
- Version: `0.1.12` (12)
- Executable SHA-256: `ca9084b39f7ffd61dbdf05c83636f67100d359e36ea2cb58af0a70e07f2d25c0`
- Architecture: `arm64`
- Hardened runtime: `26.0.0`
- Signing authority: locally signed; public authority unavailable; no team identifier

## Source proof

- Focused hands-free suites: 12 tests passed across gesture lifecycle, control-key routing, settings migration, and binding conflict handling.
- Full `make test`: 16 XCTest tests and 150 Swift Testing tests passed; the pre-existing stable-signed-fixture test skipped because its fixture is unavailable.
- Shared dictionary vectors ran inside the full suite and passed.
- `make app` passed with the stable local signing identity.
- `make install` replaced and relaunched the installed app successfully.

## Exact installed surface

- Before: `settings-before.jpeg`, 1020 × 768.
- After: `settings-after.jpeg`, 1020 × 768.
- The installed accessibility tree exposes:
  - `Enable hands-free dictation` checkbox;
  - `Hands-free key` picker, disabled while the feature is off;
  - the toggle/Enter/Escape behavior explanation.
- Visual comparison confirms the established sidebar, cards, typography, colors, spacing system, and dark appearance remain intact. Only the approved controls expanded the existing Push to talk card; no design-system token changed.

## Persistence and privacy

- The installed UI enabled hands-free with Right Command while push-to-talk remained fn.
- `/Volumes/Extreme Pro/Murmure Data/settings.json` persisted `handsFreeEnabled: true` and `handsFreeKey: rightCommand`.
- A full process termination and relaunch restored the enabled toggle and distinct binding.
- The existing TextEdit sentinel remained exactly `MURMURE RETRY SENTINEL — MUST REMAIN EXACTLY ONCE` throughout installed-surface checks.
- The implementation adds no network path. It reuses the existing local durable recording, formatting, history, and insertion flow.

## Verification boundary

Codex Computer Use cannot emit a standalone right-side modifier: it rejects modifier-only key presses, and its modifier-plus-function-key fallback did not reach Murmure's device-specific right-command event mask. Therefore a real physical toggle/Enter/Escape dictation into TextEdit was not claimed. The event tap armed successfully before and after the settings change, compilation covers the real AppKit adapter, and pure tests prove edge suppression, active-only control-key consumption, cancellation, and exactly-once finish commands. Final physical-key proof remains a short operator exercise on this Mac.
