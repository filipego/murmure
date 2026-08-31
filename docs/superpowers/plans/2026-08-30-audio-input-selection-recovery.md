# Audio Input Selection and Recovery Implementation Plan

Date: 2026-08-30

## Outcome

Let the user see available Mac input devices, keep either the system default or one explicit microphone as a local preference, test the resolved device in Settings, and recover predictably when a selected device disappears. Murmure must never change the system-wide default microphone or silently rewrite the user's explicit selection.

## Constraints

- Keep CoreAudio object IDs inside the adapter; persist only stable device UIDs and display names.
- Treat the system default as a first-class selection, resolved anew for every recording.
- When an explicit device is absent, use the current system default for capture, retain the explicit preference for reconnection, and show the fallback visibly.
- A device change during capture must stop safely with a visible error; the next start re-resolves and can fall back without relaunching.
- Do not add network access or record test audio to history.
- Reuse the existing Settings card language, design tokens, and VU instrumentation.

## Deep module boundary

`AudioInputResolver` is the pure policy boundary. Given a persisted `MicrophoneSelection`, current input devices, and current default UID, it returns a typed resolution: selected device, default fallback, or unavailable. `CoreAudioInputCatalog` is the hardware adapter that enumerates input-capable devices, maps stable UIDs to ephemeral AudioDeviceIDs, and observes device/default changes. `AudioCapture` receives a resolved adapter device instead of choosing hardware implicitly.

## Tasks

### 1. Lock the installed Settings surface

- Reuse the Phase 3 installed Settings capture as the immediate before-state.
- Record installed artifact identity and window dimensions.

### 2. Define and test selection policy

- Add `MicrophoneSelection`, `AudioInputDevice`, transport labels, and typed resolution outcomes.
- Test system-default resolution, explicit-device resolution, missing-device fallback, reconnect restoration, no-input failure, and stable Codable round trips.

### 3. Build the CoreAudio catalog adapter

- Enumerate current `kAudioHardwarePropertyDevices` and keep only devices with input channels and alive state.
- Read stable UID, display name, transport, and current default input device.
- Translate UID to AudioDeviceID only at the capture boundary.
- Observe device-list and default-input changes and publish refreshed immutable snapshots.

### 4. Persist selection compatibly

- Add optional microphone selection to the settings snapshot so old files still decode as system default.
- Keep an unavailable explicit selection intact rather than replacing it with the fallback.
- Add migration and round-trip tests.

### 5. Route live capture through the resolved device

- Resolve the preference immediately before each recording.
- Set the AVAudioEngine input unit's current device before reading its native format or installing the tap.
- Surface missing/no-input/device-configuration failures explicitly.
- Observe engine configuration changes during capture, stop the current capture safely, and make the next recording re-resolve hardware.

### 6. Add test capture and approved Settings UI

- Add an observable store/coordinator for live catalog state, fallback diagnostics, and a short level-only microphone test.
- Add a Microphone settings card with picker, current/fallback state, test button, and existing VU instrumentation.
- Disable test capture while dictation is active and stop it when the Settings surface disappears.

### 7. Verify source and installed behavior

- Run focused resolver, catalog, persistence, and test-coordinator suites.
- Run `make test`, dictionary vectors, `make app`, and `make install`.
- Compare the installed Settings window with the locked baseline.
- Exercise system default, any enumerated explicit device, the level-only test, unavailable-device fallback, and relaunch persistence.
- Record which unplug/reconnect cases were possible on attached hardware and do not claim unavailable hardware paths as physically verified.

## Acceptance

- Every live recording resolves an input device at start.
- Selecting an available explicit microphone routes capture to that CoreAudio device.
- A missing explicit microphone produces a visible default-fallback diagnostic without losing the preference.
- Reconnection restores the explicit choice automatically because the stored UID was preserved.
- Test capture shows live level without creating history, audio archives, or transcripts.
- Device changes do not crash the process or silently change the system default.
- Legacy settings, the full source suite, and shared correction vectors remain green.
