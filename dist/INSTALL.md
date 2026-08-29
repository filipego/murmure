# Murmure

Download the latest release: https://github.com/filipego/murmure/releases/latest/download/Murmure.app.zip

1. Unzip the archive and drag **Murmure.app** to `/Applications`.
2. If macOS blocks the first launch, Control-click the app, choose Open, and confirm.
3. Grant Microphone and Accessibility access, then restart Murmure after Accessibility.
4. Hold the configured push-to-talk key to dictate into the focused app.
5. Later, use Settings → Updates → Check for updates → Install and relaunch.
6. To correct a saved dictation, use the pencil Correct action on its history row.
   Review “Murmure heard” and edit “I meant”; Play original is optional, and Dictate
   only fills the draft. Remember is on by default, and Save correction is the only
   action that persists history or a safe contextual local dictionary rule. An
   interrupted rule stays pending in history and retries safely on the next launch.

Murmure stores dictionary entries, settings, transcript history, the dashboard, and
captured audio in its Murmure data folder. On this Mac that is
`/Volumes/Extreme Pro/Murmure Data`; without that drive it uses a local emergency
folder and shows the location in Settings. It never removes unrelated drive files.

Murmure processes audio, cleanup, dictionary corrections, and history locally on
your Mac. Update checks use the fixed public GitHub Releases endpoint and download
only the signed app archive. No dictation, audio, history, or dictionary data is sent.

The archive uses a stable Developer ID or local signing identity when available.
If neither is available, it falls back to ad-hoc signing and macOS may ask for
permissions again after a rebuild. This build
is not notarized unless a notarized artifact is explicitly supplied.
