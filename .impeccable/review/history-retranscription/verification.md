# History Recovery and Retranscription Verification

Date: 2026-08-30

## Outcome

Phase 2 is implemented and installed. Saved history audio plays inside Murmure, retained failed sessions appear as recoverable rows, Apple can retranscribe saved CAF files into a non-destructive preview, cancellation writes nothing, confirmation replaces one stable history row, and neither retry path inserts text into another app.

The retained failed fixture contains no recognizable speech, so its exact installed path proves visibility, playback, blank-result handling, cancellation, and no insertion but cannot prove a successful failed-session promotion. The non-inserting failed-session confirmation path is covered by real-filesystem coordinator tests. A successful installed confirmation was exercised on an existing human-voice history row. Parakeet is not installed on this Mac and was not downloaded merely to enlarge the proof matrix.

## Installed artifact identity

| Field | Value |
| --- | --- |
| Proof surface | `/Applications/Murmure.app` |
| Marketing version | `0.1.12` |
| Build | `12` |
| Bundle identifier | `ai.pivotstudio.murmur-youtube` |
| Executable | `/Applications/Murmure.app/Contents/MacOS/MurmurYouTube` |
| SHA-256 | `ab5439356a810befef89025e445df0e239ebda4338fa60487d3e66c23e78a090` |
| Architecture | `arm64` |
| Signature flags | Hardened runtime (`0x10000`) |
| Runtime version | `26.0.0` |
| Signing identity | Project-local `Design Taste Hub Local Signing`; `codesign -dv` reports no public Team ID/Authority |

## Automated verification

| Command | Result |
| --- | --- |
| `swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/test-scratch" --filter VectorTests` | 5 vector tests passed |
| `make test` | 16 XCTest tests and 138 Swift Testing tests passed; one pre-existing stable-signed-fixture test skipped |
| `make app` | App and update helper built; bundle locally signed |
| `make install` | Installed and relaunched `/Applications/Murmure.app` |
| New privacy-path `rg` audit | No `TextInjector`, `URLSession`, HTTP(S), Wispr, or other network reference in History, retranscription sheet, or archived transcriber |
| Full `TextInjector` audit | Injector remains only in normal live dictation completion |

Focused behavior added in this phase:

- 3 real-file CAF reader tests;
- 4 archived engine lifecycle tests;
- 5 durable/stale history replacement tests;
- 3 recoverable catalog/store/non-inserting completion tests, within 9 coordinator tests;
- 4 preview/confirmation/cancellation/retry tests;
- 4 playback lifecycle tests;
- 1 installed-surface status-copy regression test.

## Exact installed workflows

### Retained failed session

Fixture ID: `e46730ca-27e7-4cb7-87eb-39482d53b351`

1. Relaunched installed Murmure after restart.
2. Observed exactly one `Recoverable recordings` row with `The speech engine returned no text.` and `Audio retained locally`.
3. Clicked Play. The installed control changed from `Play recoverable recording` to `Stop recoverable recording`, then returned to Play when the CAF ended.
4. Opened retry. The installed sheet showed recovery status, Apple/Parakeet picker, local-only copy, Cancel, and Retranscribe.
5. Cancelled before processing. Manifest, CAF, and history SHA-256 values remained unchanged.
6. Retried with the installed Apple engine. The sheet returned `No words were recognized in the saved recording.` and remained retryable.
7. A TextEdit sentinel remained exactly `MURMURE RETRY SENTINEL — MUST REMAIN EXACTLY ONCE`.
8. Relaunched Murmure. The failed session still appeared once.

Durable fixture identities before and after cancel/blank retry:

| Artifact | SHA-256 |
| --- | --- |
| Failed manifest | `e7dbfe9762d748598cf4dbc71c1ce58eb11109acac2b22bb7cb272596faad513` |
| Failed CAF | `9976b1b59298b76628715039881f8c922ffd65ce9f797a76d0f03d1d38975ed4` |
| History before confirmation | `b043dc76f0f609900d119e54c8d63ec004721d6e00dff21338df468f7acc78c7` |
| History row count | `5` |

### Completed human-voice history row

Source UUID: `B3FA4AF9-CE4D-4302-81A5-308FC7AECD0C`

1. Opened retry from the installed row.
2. Apple replayed the saved CAF and produced a complete candidate in `0.58s` on the first pass.
3. Cancelled. History SHA-256 remained `b043dc…78c7` with five rows.
4. Repeated retry; Apple produced a candidate in `0.56s`.
5. Confirmed `Replace history`.
6. History SHA-256 changed to `cae41f4797c22028dc187d89cf45d3f889e441211dc7ac3113471f8f14e95198`, while row count remained exactly five.
7. The replaced row retained UUID `B3FA4AF9-CE4D-4302-81A5-308FC7AECD0C`, date `2026-08-30T20:36:04Z`, and `Recordings/b3fa4af9-ce4d-4302-81a5-308fc7aecd0c.caf`.
8. It changed engine/timing metadata and added an input method of `retranscription`, preserving the original heard text.
9. TextEdit remained unchanged.
10. Relaunched Murmure; the history still contained exactly five rows and displayed `Retranscribed locally`.

## Surface and visual ledger

| Surface | Baseline | Installed result | Visible delta |
| --- | --- | --- | --- |
| Dark main/history, 1020×768 | `../local-first-foundation/main-window-dark.jpeg` | `main-dark.jpeg` | Approved recovery section plus play/retry actions and retranscription status only; rail, header, stats, search, colors, typography, window geometry, and unaffected row structure preserved |
| Dark completed-history preview | Existing correction-sheet token family | `preview-dark.jpeg` | Approved retranscription sheet only; existing canvas/panel/well colors, typography, spacing tokens, control styling, and correction-sheet dimensions reused |
| Dark recoverable blank-result state | No prior recovery surface | `recovery-error-dark.jpeg` | Approved recovery/error surface only |
| TextEdit no-insertion sentinel | Sentinel before retry | `textedit-no-insertion.jpeg` | None |
| Light main/history and sheets | No available matching system state without global appearance mutation | Not captured | Unverified; no global appearance change was made |

No `DesignSystem.swift` token changed. Main and preview screenshots were inspected at original resolution.

## Acceptance ledger

| Outcome | Status | Evidence |
| --- | --- | --- |
| Failed session becomes visible and playable | Completed | Retained installed fixture appears once; Play/Stop exercised |
| Failed session retry never inserts | Completed | Installed Apple blank-result flow plus unchanged TextEdit sentinel; coordinator interface contains no insertion closure |
| Cancel changes nothing | Completed | Manifest/CAF/history hashes unchanged after both recovery and history cancel paths |
| Completed history audio plays in-app | Completed | Installed row uses Play/Stop; playback lifecycle tests pass |
| Completed history retranscribes to preview | Completed for Apple | Installed human-voice CAF produced candidate twice |
| Explicit confirmation replaces one row | Completed | Stable UUID/date/audio path, five rows before and after, checksum changed only after confirmation |
| Relaunch duplicates neither history nor recovery | Completed | Five history rows and one recovery row after relaunch |
| Successful failed-session promotion on installed surface | Unverified | Retained fixture is blank; real-filesystem coordinator tests prove non-inserting, idempotent promotion |
| Parakeet installed-engine retry | Unverified/not applicable on this Mac | Model path absent; picker and download warning present, but the 470 MB model was not installed for proof |
| Dark protected visuals | Completed | Like-for-like installed screenshots inspected |
| Light protected visuals | Unverified | Would require changing global appearance; not authorized |
| Original Phase 1 live microphone insertion | Unverified | Synthetic speaker audio was not audible enough to the selected mic; retained failure remains recoverable |

## Scope preserved

- No Windows changes.
- No cloud speech, paid API, account, subscription, telemetry, MCP, wake word, or commercial feature.
- No dictionary vector change.
- No new network request.
- No visual redesign or design-token mutation.
