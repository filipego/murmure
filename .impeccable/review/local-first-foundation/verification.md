# Durable local dictation foundation verification

Verified on the installed `/Applications/Murmure.app` built from commit `7579eed` plus the pending documentation-only cleanup.

## Automated proof

- `make test`: passed
- XCTest: 9 tests passed
- Swift Testing: 121 tests across 14 suites completed without failures
- Existing intentional skip: stable signed-fixture validation was unavailable
- Shared dictionary vectors: passed unchanged
- `make app`: passed

## Bundle and installed artifact

- Marketing version: `0.1.12`
- Build: `12`
- Architecture: thin Mach-O `arm64`
- Built binary SHA-256 before final installation signing: `517be7ca85c3a62034725a27cf81e2a5241b49f0a3ef61c92c1f7144efe1d5b1`
- Installed binary SHA-256: `39627572f139892949d37314123d4799ceaf19f01b042538f055fdef9f6e7e2d`
- Signature: hardened-runtime local certificate was applied
- Trust: `CSSMERR_TP_NOT_TRUSTED`, expected for this private, non-notarized local certificate

## Installed surfaces

| Surface | Evidence | Result |
| --- | --- | --- |
| Main window and history | `main-window-dark.jpeg` | Existing history, controls, spacing, color, and typography remain present. |
| Settings | `settings-dark.jpeg` | Existing controls and granted permissions remain present with no unrelated visual delta. |
| Engine comparison | `comparison-dark.jpeg` | Installed copy says `Record both` and names only Apple and Parakeet sharing the same local recording. |
| Recovery target before relaunch | `recoverable-failure-no-insertion.jpeg` | Disposable TextEdit document remained empty after the failed recognition. |
| Recovery target after relaunch | `relaunch-no-insertion.jpeg` | TextEdit remained empty after installed-app launch recovery. |

## Real recording and recovery proof

The installed app received a real `fn` hotkey cycle while local synthesized speech played. The selected microphone did not hear enough speech for recognition, which exercised the failure boundary rather than successful insertion.

- Session manifest: `recoverable-session-manifest.json`
- Staged CAF size: 205,378 bytes
- Staged CAF SHA-256: `9976b1b59298b76628715039881f8c922ffd65ce9f797a76d0f03d1d38975ed4`
- Durable status: `failed`, stage `transcription`
- Trigger recorded: hold-to-talk binding `fn`
- History result: no false row was appended
- Insertion result: no text was inserted before or after relaunch
- Relaunch result: the manifest and CAF remained intact

This directly proves local staging, durable failure classification, retained audio, and non-inserting recovery on the installed artifact. A successful exact-surface voice insertion remains pending because the synthesized speaker output was not audible to the selected microphone.

## Privacy inspection

- Runtime Wispr trigger and reader files are removed.
- Runtime searches found no `WisprTrigger`, `WisprReader`, Wispr wait state, or three-engine recording copy.
- Comparison participants are guarded by a test that permits only Apple and Parakeet.
- Source network use is confined to GitHub release/update transport and package/model acquisition paths; no transcript or staged-audio upload path exists.
- Product-name text remains only in a dictionary example/specification fixture and does not execute network behavior.

## Remaining phase-gate proof

- One audible human phrase must be dictated into a disposable local field to prove successful installed insertion exactly once and the corresponding promoted history audio row.
- Light appearance remains pending because changing the user's global appearance was not authorized.
