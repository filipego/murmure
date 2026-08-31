# Murmure

**Requirements: Apple Silicon (M1 or newer) and macOS 26 or later.**
This modern archive does not support Intel Macs. Intel remains a separate hardware
compatibility investigation; do not bypass this requirement.

Download the latest release: https://github.com/filipego/murmure/releases/latest/download/Murmure.app.zip

1. Unzip the archive and drag **Murmure.app** to `/Applications`.
2. If macOS blocks the first launch, Control-click the app, choose Open, and confirm.
   If needed, use System Settings → Privacy & Security → Open Anyway.
3. Follow Set up Murmure. Grant Microphone and Accessibility access yourself, choose
   a shortcut, test the microphone, choose language behavior, and finish one test.
4. Automatic uses the free local Parakeet model to recognize 25 European languages.
   The first use may download that model. Explicit languages can use Apple Speech.
5. Hold the configured push-to-talk key in any app, speak, then finish the gesture.
6. Later, use Settings → Updates → Check for updates → Install and relaunch.
7. To correct a saved dictation, use the pencil Correct action on its history row.
   Review "Murmure heard" and edit "I meant"; Play original is optional, and Dictate
   only fills the draft. Remember is on by default, and Save correction is the only
   action that persists history or a safe contextual local dictionary rule. An
   interrupted rule stays pending in history and retries safely on the next launch.
8. Command Mode edits selected text with Apple's on-device model. Select editable
   text in another app, hold Control-Option-Command-D, speak the change, then release.
   Review the proposal before replacing the selection, or copy it instead. Settings
   explains if Apple Intelligence is unavailable. There is no network fallback.

Snippets replace an exact whole spoken phrase with reusable local text. Automatic
recognition, deterministic cleanup, snippets, dictionary corrections, history, and audio
all run locally. Model downloads and update checks are the only network operations.

Murmure stores settings, snippets, dictionary entries, transcript history, and captured
audio in its local data folder under Application Support. On the operator Mac only,
the specifically configured Extreme Pro drive is used when mounted. Settings always
shows the active location. Installation and app updates never replace that data folder,
and Murmure never removes unrelated drive files.

Use Settings → Setup and diagnostics to rerun setup or preview/copy/export a sanitized
report. Diagnostics contain app, Mac, engine, language, model, permission, microphone,
and storage status only. They never include dictated text, history, audio, snippets, dictionary data,
or local file paths.

The archive uses a stable Developer ID or local signing identity when available.
If neither is available, it falls back to ad-hoc signing and macOS may ask for
permissions again after a rebuild. This build
is not notarized unless a notarized artifact is explicitly supplied.
