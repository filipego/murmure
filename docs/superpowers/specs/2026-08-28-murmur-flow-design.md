# Murmure: local voice desk

Status: approved from the user brief and ready for implementation.

## Product contract

Murmure is a native macOS push-to-talk dictation desk. It turns speech into
polished text on-device, inserts the result into the focused app, and keeps a local,
searchable history. It must remain useful without an account, a hosted API, or a
subscription.

The upstream repository is the engine baseline. The visual shell is being replaced with
a calmer, Wispr Flow-inspired hub that has its own name, copy, palette, and icon language.
The app does not copy Wispr assets, branding, or cloud features. Notetaker remains out of
scope for this pass; the video explicitly did not build it, and the request is to improve
the shell around the local dictation workflow.

## Direction contract

The concept-seed roll selected candidate four from the following grounded set:

1. warm studio console
2. quiet writing room
3. compact audio notebook
4. calm command center
5. monochrome utility desk
6. editorial transcript library
7. local-first workshop

Candidate four is the chosen direction: a calm command center with a mostly monochrome
surface, a single warm recording accent, strong information hierarchy, and keyboard-first
state clarity. The roll is subordinate to the user-pinned Wispr-like hub direction. A
phosphor-terminal challenger was considered for its keyboard discipline, but its dark
terminal surface was rejected because it reduced transcript readability. The lexicon
challenger was kept only as a density cue for history and dictionary rows.

Visual rules:

- Use a quiet warm-white canvas, charcoal navigation rail, and one orange-red recording
  accent. No neon, decorative gradients, fake glass, or subscription upsell.
- Use system typography with a clear display/title role, a compact label role, and readable
  transcript body text. Information density should feel intentional, not cramped.
- Keep the primary action visible at all times. Recording states must be readable by text,
  icon, and motion, not color alone.
- Preserve the floating HUD as a non-activating panel so dictation never steals focus.
- Prefer native controls and keyboard navigation. Every destructive action remains explicit.

## User-facing surfaces

### Home

The main window opens to Home. It contains a short welcome line, three compact local stats
(sessions, words, current push-to-talk key), a prominent record action, and a searchable
history list grouped by recent day. Each history row exposes copy and delete actions and
shows dictionary corrections when they fired.

### Dictionary

The existing dictionary file and editor remain the source of truth. The new shell presents
terms and corrections as a readable list with search, add, edit, enable/disable, delete,
and a link to the editable local file.

### Settings

Settings keep the existing engine, cleanup, smart on-device cleanup, sound, and hotkey
controls, but use the same visual system as Home. Permission state is visible and links to
the relevant macOS settings panes. A Local update card shows the current version and any
staged update.

### HUD

The HUD keeps its current non-activating AppKit behavior and is restyled as a compact,
high-contrast voice status pill. It shows listening, transcribing, live text, and error
states without using a gradient or stealing focus.

## Data shapes and module seams

The first implementation step names the data before adding views.

```swift
enum HubSection: String, CaseIterable, Identifiable {
    case home, dictionary, settings
}

enum UpdateState: Equatable {
    case idle
    case checking
    case available(UpdateManifest)
    case installing
    case failed(String)
}

struct AppVersion: Codable, Comparable, Equatable, Sendable {
    let marketing: String
    let build: Int
}

struct UpdateManifest: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let version: AppVersion
    let stagedBundleURL: URL
    let createdAt: Date
}
```

`AppUpdateCoordinator` is the deep module for staged local updates. Its interface owns
manifest loading, version comparison, staging-path validation, and launching the small
bundled helper. SwiftUI sees only `state`, `checkForStagedUpdate()`, and
`installAvailableUpdate()`. It never constructs shell commands or knows the copy protocol.

`MurmurUpdateHelper` is a separate executable target. It receives validated source and
destination bundle paths, waits for the parent app to exit, atomically moves the existing
bundle to a timestamped backup, copies the staged bundle into place, and relaunches the
destination. It rejects paths that are not a Murmure bundle and never traverses a
user-supplied shell string.

The Makefile remains the packaging authority:

- `make app` builds with a stable Developer ID or local signing identity when available,
  falling back to ad-hoc only when neither identity exists.
- `make stage-update` copies that app to the local Application Support update inbox and
  writes `manifest.json`.
- `make share` produces `dist/Murmure.app.zip` and a short `dist/INSTALL.md`.
- `make install` remains the explicit install path for `/Applications`.

The stable bundle identifier remains `ai.pivotstudio.murmur-youtube`, so a stable
Developer ID or local signing signature can preserve TCC permissions. On machines without
either identity, the package is ad-hoc and the installer README says that macOS may ask for
permissions again. No claim of notarization is made unless a notarized artifact is actually
produced.

## Acceptance ledger

| Outcome | Target surface | Protected behavior / exclusion | Proof | Status |
| --- | --- | --- | --- | --- |
| Full video and comments understood | watch transcript, sampled visual frames, visible comments | no invented product behavior | saved transcript, visual notes, comment notes | completed |
| Upstream engine reused | Swift sources and build | local Apple/Parakeet path, dictionary, focus-safe injection | source diff plus full build/test | completed |
| Wispr-inspired hub shell | native main window and settings | own branding, no cloud/account/notetaker scope | built app screenshot and interaction check | pending |
| Wispr-inspired hub shell | native main window and settings | own branding, no cloud/account/notetaker scope | installed app screenshot and native navigation check | completed |
| Local on-device cleanup | dictation pipeline | no remote API or transcript upload | source inspection and full test/build | completed |
| History and dictionary remain useful | Home and Dictionary sections | local files remain compatible | existing vectors, empty-history surface, populated dictionary/action-tree capture | implemented; history data/editor submission unverified |
| Staged in-app update button | installed app Settings/Home | exact bundle ID/path, idempotent helper | available-state capture, helper E2E, manifest, tests | completed |
| Friend-shareable artifact | `dist` zip and install guide | honest signing/notarization boundary | archive inspection and checksum | completed |
| External-drive data ownership | `Murmure Data` on the mounted drive | no unrelated drive files deleted or overwritten; legacy data copied safely | folder/README, source path audit, and packaged install notes | implemented; live audio capture still requires user permission |
| Actual native surface verified | built `.app`, and installed path where permitted | no source-only completion claim | `/Applications` launch and screenshots; capability caveats recorded | completed with caveats |

## Verification contract

Before production code, add failing tests for manifest parsing, version comparison, path
validation, and the helper's temp-directory replacement flow. Then run the existing
dictionary vectors and the full Swift test suite. Build the real `.app`, inspect its
Info.plist and nested helper, stage an update, and verify the packaged zip contents.

The final review must check the main window at its minimum size, a populated history, an
empty history, dictionary editing, recording/listening/finishing/error states, dark and
light appearance, keyboard focus, and update states. Native surface proof is preferred;
if macOS blocks GUI automation in this environment, report the exact artifact and the
unverified interaction rather than substituting a source-only claim.

## Evidence

- Reference video: https://www.youtube.com/watch?v=IMQw3aHjf2Q
- Upstream implementation: https://github.com/per-simmons/murmur-youtube
- Wispr Flow feature model: https://wisprflow.ai/features
- Wispr desktop navigation: https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android
- Existing local engine and formatter: `Sources/MurmurYouTube/Core/DictationController.swift`,
  `Sources/MurmurYouTube/Formatting/FoundationModelFormatter.swift`
