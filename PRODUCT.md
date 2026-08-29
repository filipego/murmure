# Murmure

<!-- impeccable:product-schema 1 -->

## Platform

macos

## Stack

Swift 6.2, SwiftUI, AppKit, Swift Package Manager, and the existing native macOS implementation from `per-simmons/murmur-youtube`.

## Users

The primary user is Filipe, dictating into the app or into the text field that already has focus in another macOS app. Trusted coworkers and friends are a secondary audience who should be able to install the app without a hosted account.

## Product Purpose

Murmure turns push-to-talk speech into polished text locally on the Mac. It removes the subscription and data-sharing dependency of hosted dictation tools while keeping the fast, calm workflow people expect from Wispr Flow. Success means a short hold, a clear live state, reliable insertion at the existing caret, and a history the user can revisit.

## Positioning

The differentiator is ownership of the complete path. Audio, transcription, cleanup, dictionary corrections, and history stay on the device by default. The same app can be shared as a native macOS package without requiring a service account.

## Operating Context

The app runs as a normal macOS application with a menu-bar presence, a main hub window, a non-activating recording overlay, and a global push-to-talk key. It must preserve the focused target app while recording and after text injection. Updates are initiated from inside the installed app so the user does not need to replace the application bundle by hand.

## Capabilities and Constraints

- Hold a configurable hotkey to record and release to finish.
- Use Apple SpeechAnalyzer/SpeechTranscriber by default, with the existing Parakeet option available as a local alternative.
- Run deterministic cleanup or Apple's on-device Foundation Models cleanup. No transcript text or audio is sent to a remote API by the default workflow.
- Apply a local correction dictionary and keep a searchable transcription history.
- Save transcript history, dictionary entries, settings, dashboard output, and captured CAF
  recordings under `/Volumes/Extreme Pro/Murmure Data` without touching unrelated files on
  the drive. If the drive is unavailable at launch, show the fallback clearly.
- Keep the existing bundle identity and use a stable Developer ID or local signing identity
  so Accessibility and Microphone grants survive rebuilds and in-app updates.
- Produce a shareable macOS `.app` archive and document the optional signing/notarization boundary honestly.
- The product does not include Wispr Flow branding, assets, account sync, or hosted Notetaker data.
- The product name is **Murmure**. The internal SwiftPM target and bundle identifier remain
  stable so existing macOS permissions and staged updates survive the rename.

## Brand Commitments

The shell should feel closer to the real Wispr Flow hub than to the video's tape-recorder experiment. Use Whisperflow/Wispr Flow only as a design reference. The app keeps its own name, copy, icon, and local-only promise. The interface should be quiet, editorial, fast to scan, and confident without neon, fake gradients, or a subscription upsell.

## Evidence on Hand

- Full reference video and transcript: `https://www.youtube.com/watch?v=IMQw3aHjf2Q`.
- Upstream working native implementation: `https://github.com/per-simmons/murmur-youtube`.
- Official feature and navigation references: `https://wisprflow.ai/features` and `https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android`.
- Existing code paths for recording, local cleanup, dictionary storage, history, permissions, and stable app staging are in `Sources/MurmurYouTube` and `Makefile`.

## Product Principles

- Local by default. Do not add a network dependency to the dictation path.
- Fast state clarity. The user should know whether the app is idle, recording, processing, or ready.
- Preserve focus. Recording UI must never steal the target caret.
- Useful polish. Cleanup, dictionary corrections, and history should reduce editing rather than decorate the workflow.
- Share without surprises. A friend should receive a coherent installable app and clear permission steps.

## Accessibility & Inclusion

Keep native macOS keyboard navigation, visible focus, readable contrast, and descriptive labels. Do not rely on color alone for recording, processing, or error states. Respect the permission boundary and explain microphone and Accessibility requirements in user language.
