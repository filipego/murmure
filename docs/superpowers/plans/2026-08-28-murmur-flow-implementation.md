# Murmure shell, staged updates, and share package

> **For the implementation agent:** Execute this plan task by task. Keep the local engine
> and dictionary contracts intact. Use the exact paths below and keep tests ahead of the
> implementation for every new pure function.

**Goal:** Turn the upstream macOS app into a polished, Wispr Flow-inspired
local voice desk with a durable staged-update button and a shareable archive.

**Architecture:** Keep `DictationController`, the Apple/Parakeet engines, `RunLog`, and
`DictionaryStore` as the domain seams. Add a `MurmurUpdateCore` library, a
`MurmurUpdateHelper` executable, and an `AppUpdateCoordinator` adapter in the app. Replace the tape-specific SwiftUI shell with a
three-section hub while preserving the non-activating HUD and menu-bar entry point.

**Tech:** Swift 6.2, SwiftUI, AppKit, Swift Package Manager, XCTest, Makefile, macOS 26.

## 1. Establish the data shapes and failing tests

Files:

- Create `Sources/MurmurUpdateCore/UpdateCore.swift`.
- Create `Sources/MurmurYouTube/Support/AppUpdateCoordinator.swift`.
- Create `Sources/MurmurUpdateHelper/main.swift`.
- Create `Tests/MurmurYouTubeTests/UpdateCoordinatorTests.swift`.
- Update `Package.swift` with the helper executable and app test target.

Define `HubSection`, `AppVersion`, `UpdateManifest`, and `UpdateState` exactly as the design spec
describes. Define a small `UpdateFileSystem` protocol or equivalent injectable seam so
manifest loading and version comparison can be tested without touching the user's
Application Support folder.

Write tests first for:

1. decoding a valid manifest and rejecting missing/invalid fields;
2. treating semantic versions and build numbers deterministically;
3. accepting only a bundle whose identifier is
   `ai.pivotstudio.murmur-youtube` and whose executable exists;
4. copying a staged bundle into a temporary destination and preserving a backup;
5. idempotently handling a second apply request.

Run the focused tests and capture the expected failures before writing the implementation.

## 2. Implement the update module and helper

Files:

- Implement `AppUpdateCoordinator` in `Sources/MurmurYouTube/Support/AppUpdateCoordinator.swift`.
- Implement the command-line helper in `Sources/MurmurUpdateHelper/main.swift`.
- Extend `Resources/MurmurYouTube.entitlements` only if the helper requires it; avoid new
  network entitlements.

Keep the coordinator's public surface small: `state`, `currentVersion`,
`checkForStagedUpdate()`, and `installAvailableUpdate()`. Resolve the local update inbox
under `~/Library/Application Support/MurmurYouTube/Updates`, load `manifest.json`, and
compare it with the running bundle. Launch the nested helper with structured arguments,
terminate the app, and let the helper wait, replace, and relaunch. Validate every path
before launching and never interpolate an untrusted path into a shell command.

Run the focused tests, then the existing dictionary tests.

## 3. Add packaging and sharing targets

Files:

- Update `Makefile`.
- Create `dist/INSTALL.md` through the `share` target rather than checking in a generated
  archive.

Add:

- `stage-update`: build the app, copy the exact staged bundle into the update inbox, and
  write a manifest containing the bundle version, build, path, and creation date.
- `share`: build the app, produce `dist/Murmure.app.zip` with `ditto`, and write a
  concise install guide describing drag-to-Applications, first-run microphone and
  Accessibility permissions, local-only processing, and the ad-hoc versus Developer ID
  signing boundary.

Keep `make install` explicit and preserve its stable destination. Do not add a remote
appcast or cloud service.

Verify the staged manifest and zip contents with `plutil`, `unzip -l`, and a checksum.

## 4. Replace the native shell

Files:

- Rewrite `Sources/MurmurYouTube/UI/DesignSystem.swift` with the calm command-center
  tokens from the direction contract.
- Rewrite `Sources/MurmurYouTube/UI/MainWindow.swift` around Home, Dictionary, and Settings.
- Restyle `Sources/MurmurYouTube/UI/DictionaryPanel.swift` and
  `Sources/MurmurYouTube/UI/SettingsWindow.swift` using the shared tokens.
- Restyle `Sources/MurmurYouTube/UI/HUDView.swift` while preserving `HUDPanel`'s
  non-activating behavior.
- Update `Sources/MurmurYouTube/MurmurYouTubeApp.swift` only where the new coordinator or
  section routing needs integration.

Home should show a welcome line, local stats, an always-visible record action, a searchable
history, copy/delete affordances, and correction badges. Dictionary behavior and file
reveal remain intact. Settings should expose the existing engine, cleanup, smart cleanup,
sound, and hotkey controls plus permission links and the update card.

Use native controls, explicit labels, visible focus, sufficient contrast, and text/state
announcements. Keep the main window usable at 720×520 and avoid decorative-only elements.

Build after each surface group so compiler errors stay local.

## 5. Wire the app and verify behavior

Files:

- Update `Sources/MurmurYouTube/MurmurYouTubeApp.swift` to create/inject one coordinator.
- Update menu content with a compact update status action if it improves discoverability.

Run `swift test --scratch-path "$HOME/Library/Caches/MurmurYouTubeBuild/scratch"`, then
`make build`, `make app`, and `make stage-update`. Inspect bundle identifier, version,
helper presence, signature status, staged manifest, and archive contents.

Exercise pure state transitions for idle/listening/finishing/error, empty/populated history,
dictionary editing, update unavailable/available/installing/failed, and dark/light tokens.
Launch the staged app if GUI access permits and capture a screenshot at the minimum size;
otherwise retain the exact build artifacts and state native interaction proof as unverified.

## 6. Review and acceptance audit

Use the acceptance ledger in `docs/superpowers/specs/2026-08-28-murmur-flow-design.md`.
Review the complete diff for accidental API/network additions, shell quoting, duplicated
state, and visual regressions. Run the Impeccable manual detector when the app has a
web-rendered surface; for this native-only app, do the equivalent token/source audit and
record the result in `.impeccable/review/`. Do not claim notarization or a successful
in-app replacement unless the corresponding artifact and runtime proof exist.
