# Murmure

Push-to-talk dictation for macOS. Hold a key, talk, release — cleaned-up text lands in
whatever text field has focus. A Wispr Flow-inspired app, built native and fully on-device.

**Status:** working native app. Builds, launches, arms the hotkey, transcribes, injects,
keeps searchable history, and archives captured microphone audio as local CAF files.

---

## Coexisting with another dictation app

This app is built to run alongside other dictation tools without colliding with them, which
is not automatic on macOS and is worth understanding before changing anything:

- **Bundle ID `ai.pivotstudio.murmur-youtube`** — TCC keys Accessibility and Microphone
  grants to the bundle ID, so granting or revoking a permission here has no effect on any
  other app, and vice versa.
- **Executable `MurmurYouTube`** — distinct enough that `pkill -x MurmurYouTube` cannot
  match a differently-named binary. The `Makefile` only ever targets `$(EXEC)`.
- **Hotkey is configurable** (Right ⌥ / fn / Right ⌘) precisely because another tool may
  already own the key you'd reach for first. The event tap inspects only its own keycode
  and passes everything else through untouched.

If you run more than one dictation app, give each a different push-to-talk key. Two apps on
the same key both record, and whichever injects text will fight the other.

---

## Quick start

```bash
make install     # builds, bundles, signs, copies to /Applications, launches
```

Then grant two permissions — neither is optional, and neither can be requested silently:

| Permission | Where | Needed for |
|---|---|---|
| **Accessibility** | System Settings ▸ Privacy & Security ▸ Accessibility | The `CGEventTap` that sees the hotkey, and the AX text insert |
| **Microphone** | Request access from Settings, or on first dictation | Audio capture |

Restart Murmure after granting Accessibility. Then hold **Right ⌥** and talk.

### Data location

Murmure keeps its user-created data in `/Volumes/Extreme Pro/Murmure Data` when that drive
is mounted. The folder contains `runs.jsonl`, `dictionary.txt`, `settings.json`, the generated
`dashboard.html`, and `Recordings/*.caf`. On first launch the app creates only this dedicated
folder and copies any legacy Murmur files into it without deleting the originals or touching
unrelated files on the drive. Settings shows the active location and a Finder reveal action.

### Why grants survive rebuilds here

TCC stores a *code-signing requirement* per entry, not just a path. An ad-hoc signature
changes on every build, so the rebuilt binary stops satisfying the stored requirement —
and the symptom is nasty: the Accessibility toggle still **shows as on** while the app is
reported untrusted, and flipping it changes nothing because the stale row is the problem.

The `Makefile` therefore prefers a stable Developer ID, then a stable local signing
certificate already on this Mac (both are auto-detected via `security find-identity`),
falling back to ad-hoc only when neither exists. A stable identity keeps the designated
requirement constant, so rebuilds and the in-app updater do not invalidate the grant.

If a grant ever does get wedged, reset that one row and re-add — never toggle:

```bash
tccutil reset Accessibility ai.pivotstudio.murmur-youtube
tccutil reset Microphone   ai.pivotstudio.murmur-youtube
```

Always pass the bundle ID. A bare `tccutil reset Accessibility` wipes **every** app on the
machine. Then quit System Settings entirely (⌘Q) before reopening — that pane caches its
list and will otherwise show the row you just deleted.

> **Keep the build out of iCloud.** `~/Desktop` and `~/Documents` are file-provider synced
> on this machine; the sync engine can materialize/dematerialize files inside an `.app` and
> corrupt its signature. `make install` puts the running copy in `/Applications`.

Other targets: `make app` (bundle only), `make run` (run in place), `make clean`.

## Read more: install, use, and share

Murmure is a native macOS push-to-talk dictation desk. Hold the configured key, speak, and
release it; the cleaned text is inserted into whichever text field already has focus. Audio,
transcription, cleanup, dictionary corrections, and history stay on the Mac by default. No
account is required.

### Learn the workflow

Download the companion guide: [Murmure User Guide](docs/Murmure-User-Guide.pptx).

The short version is:

1. Launch Murmure and grant **Microphone** and **Accessibility** access. Restart the app after
   granting Accessibility so macOS refreshes the event-tap trust.
2. In **Settings**, choose the push-to-talk key. Apple is the streaming default; Parakeet is a
   local batch alternative. Turn on **Clean up transcripts** for punctuation and filler cleanup.
   **Smart cleanup (on-device AI)** adds Apple's local language-model pass; it does not listen
   to the audio a second time.
3. Focus a text field, hold the key, speak naturally, then release. The HUD shows recording and
   processing without stealing focus.
4. If a name or product term is often misheard, open **Dictionary → Add entry**. Use a **Term**
   for a word the engine should recognize, or a **Correction** such as `banana -> Marina` when
   the same mistake repeats. Entries are saved to the Murmure data folder.

### Correct and remember a dictation

From a history row, choose the pencil **Correct** action. Review **Murmure heard** alongside the
editable **I meant** text; **Play original** replays the retained recording when one exists.
**Dictate** is optional and only fills the draft — it never saves by itself. **Remember for future
dictations** is on by default, but only safe, contextual rewrites are added to the local
dictionary. **Save correction** is the single persistence boundary: it updates the history row and
then confirms the safe dictionary rule. If the drive or app interrupts that handoff, the history
marks the rule pending and Murmure retries it safely on the next launch. Audio, history, and
dictionary data stay local, on the external Murmure data drive when mounted (or in the app's local
emergency folder).

### Install the prebuilt archive (recommended for friends)

1. Download [`dist/Murmure.app.zip`](dist/Murmure.app.zip) from this repository and unzip it.
2. Drag **Murmure.app** into `/Applications` and launch it.
3. This development archive is signed but **not notarized**. If macOS blocks the first launch,
   Control-click the app, choose **Open**, and confirm. If needed, use System Settings → Privacy
   & Security → **Open Anyway**.
4. Grant Microphone and Accessibility access when macOS asks. The friend must do this on their
   own Mac; Codex cannot grant TCC permissions for them.
5. If the Extreme Pro drive is not mounted, Murmure uses its local emergency folder at
   `~/Library/Application Support/MurmurYouTube` and shows that status in Settings. It never
   deletes or overwrites unrelated files on a drive.

### Build and install from source

Source installation requires macOS 26 and a Swift/Xcode toolchain:

```bash
git clone https://github.com/filipego/murmure.git
cd murmure
make install
```

Use the repository Makefile rather than a bare `swift build`; it builds outside synced folders,
assembles the real app bundle, signs it, installs it in `/Applications`, and launches it. A
source build still needs the two macOS permissions above. `make share` creates a fresh
`dist/Murmure.app.zip` and install notes.

### Copy-paste prompt for Codex

Give a friend this prompt after they open Codex:

```text
Install Murmure from https://github.com/filipego/murmure.git.

Read README.md and AGENTS.md before changing anything. This is a native macOS 26 Swift app.
Use the repository Makefile (`make install`), not a bare `swift build`. Check that the required
Swift/Xcode toolchain is available, and ask for approval before running commands that write to
/Applications. Do not delete or modify unrelated files, especially anything on an external
drive. After installation, tell me exactly how to grant Microphone and Accessibility access,
how to run one short test dictation, and where Murmure is storing local data.
```

Codex can build and install the source, but the friend must approve any requested commands and
grant the macOS permissions themselves. Each person gets their own local dictionary, history,
and recordings; do not share your `Murmure Data` folder, credentials, or signing keys.

### Updates after sharing

The in-app **Local update** button installs a validated bundle staged on that Mac (developers
can create one with `make stage-update`). It is intentionally not a hosted updater. A friend
who receives a newer GitHub archive must download the new archive and replace the old app, or
ask Codex to pull the repository and run `make stage-update`; then they can use Settings → Local
update → **Check for staged update** → **Install and relaunch**. Existing permissions survive
when the same stable bundle identity is retained.

---

## Architecture

```
 hold key ─► HotkeyMonitor ──► DictationController ◄── Settings
                                │
                     ┌──────────┼──────────┐
                     ▼          ▼          ▼
              AudioCapture  HUDPanel   TranscriptionEngine
                     │                      │
                (AudioChunk) ──ordered──► AppleSpeechEngine
                                            │
                                       (transcript)
                                            ▼
                                      TextFormatter
                                            ▼
                                      TextInjector ─► focused app
```

### Decisions worth knowing

**The HUD must never take focus.** `HUDPanel` is a `.nonactivatingPanel` with
`canBecomeKey == false`. This is the load-bearing detail of the whole app: if the overlay
took key status, the user's text field would lose focus and there'd be nothing left to
inject into. Everything else is replaceable; this isn't.

**The hotkey needs a `CGEventTap`, not `NSEvent`.** `fn` and left/right modifier
discrimination don't surface through `NSEvent.addGlobalMonitorForEvents` or the Carbon
hotkey API. A session event tap is the only way to see them — which is why Accessibility
permission is a hard requirement rather than a nicety.

**Audio ordering is explicit.** `AudioCapture` yields into an `AsyncStream` drained by a
single task. Spawning a `Task` per buffer would be simpler and would silently corrupt the
transcript, because unstructured tasks have no ordering guarantee.

**Buffers are copied, never borrowed.** `AVAudioEngine` recycles the buffer it hands to a
tap the instant the callback returns. `AudioChunk`'s `@unchecked Sendable` is only sound
because `AudioCapture` always allocates fresh storage before handing off.

**Audio history has its own format boundary.** `MurmurAudioCore` converts the ordered chunks
to one explicit 16 kHz mono PCM format before writing a CAF, so Core Audio never receives a
buffer whose processing format differs from the file.

**Two swappable seams.** `TranscriptionEngine` and `TextFormatter` are protocols so the
two components most likely to change can change without touching anything else.

### Layout

```
Sources/MurmurYouTube/
├── MurmurYouTubeApp.swift              @main, AppDelegate, MenuBarExtra
├── Core/
│   ├── DictationController.swift   state machine, wires everything
│   ├── HotkeyMonitor.swift         CGEventTap on .flagsChanged
│   ├── AudioCapture.swift          AVAudioEngine tap + format conversion + RMS
│   └── TextInjector.swift          AX insert, pasteboard+⌘V fallback
├── Transcription/
│   ├── TranscriptionEngine.swift   protocol + AudioChunk
│   └── AppleSpeechEngine.swift     SpeechAnalyzer / SpeechTranscriber
├── Formatting/
│   └── TextFormatter.swift         protocol + RuleBasedFormatter
├── UI/
│   ├── HUDPanel.swift              non-activating floating panel
│   └── HUDView.swift               waveform + live transcript, Brand palette
└── Support/
    ├── Settings.swift, Permissions.swift, Log.swift
    └── MurmureDataStore.swift           external-drive data root + audio history

Sources/MurmurAudioCore/
└── AudioArchiveCore.swift                canonical PCM conversion + CAF writer
```

---

## Speech engine

Default is Apple's **`SpeechAnalyzer` / `SpeechTranscriber`**, new in macOS 26: no
dependency, no bundled model, no cloud path, real streaming with `.volatileResults` so
text appears while you're still talking. The OS downloads and manages model assets, so the
first run for a locale may pause on `AssetInstallationRequest`.

The intended upgrade is **Parakeet v3** via FluidAudio (CoreML on the Neural Engine) —
measurably better English WER, ~110× realtime, ~66 MB resident. Implementing
`TranscriptionEngine` is the entire cost of switching; `DictationController` doesn't
change.

| | Apple SpeechTranscriber | Parakeet v3 (FluidAudio) | Whisper large-v3 (WhisperKit) |
|---|---|---|---|
| Dependency | none | SwiftPM | SwiftPM |
| Model download | OS-managed | ~600 MB | ~1.5 GB |
| English accuracy | good | best | good |
| Languages | many | 25 | 99 |
| Latency | low | ~80 ms | 200–500 ms |

---

## Next steps

1. **Command Mode.** Select text, hold a second hotkey, say "make this more formal."
   Needs AX read of `kAXSelectedTextAttribute` plus an LLM round-trip.
2. **Advanced personal language model.** The local dictionary already corrects terms and
   exposes them to the engines; a future release could feed those entries into
   `SpeechAnalyzer`'s `AnalysisContext` / `SFCustomLanguageModelData`.
3. **Onboarding.** A first-run window that walks through both permissions instead of
   relying on the menu's "Grant…" items.
4. **Public distribution signing + notarization.** A Developer ID/notarized build is still
   needed to remove Gatekeeper friction for friends; local signing keeps this machine's
   permissions stable during development.

---

## Verified

Driven with a synthetic Right ⌥ hold (`scratchpad/ptt/ptt2.swift` posts `flagsChanged`
events) and confirmed via `/usr/bin/log show --predicate 'subsystem ==
"ai.pivotstudio.murmur-youtube"'`:

- Builds clean under Swift 6 strict concurrency.
- Signs with the stable local signing identity available on this Mac; grants survive
  rebuilds and in-app updates.
- Launches as a regular app with a Dock icon, a menu bar item, and a standard window.
- Event tap arms on grant without a restart (the poller catches it).
- Full state machine: `starting → listening → finishing → idle`, no errors.
- `SpeechAnalyzer` starts; models already installed, no download stall.
- Audio capture runs and converts native 48 kHz → 16 kHz for the engine.
- Audio history normalizes mixed capture buffers to an explicit 16 kHz mono CAF; the regression
  fixture writes a playable archive without the Core Audio stop-time abort.
- HUD renders bottom-center at `{{790, 96}, {340, 76}}` without taking focus.
- Silence produces an empty transcript and injects nothing.

**Not yet verified:** speech → transcript → cleanup → injection. Synthetic key events
can't produce audio, so this needs a human to hold the key and talk.

> `log` is shadowed in this shell — use `/usr/bin/log` explicitly or it returns nothing.
