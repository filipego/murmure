# GitHub Releases Updater Design

## Goal

Turn the existing local staged-update button into a real GitHub Releases updater. A friend installs Murmure once, grants macOS permissions once, and later uses Settings to check, download, validate, install, and relaunch a newer release without replacing the app manually.

## Scope and constraints

- The update source is the public repository `filipego/murmure`.
- Stable releases use tags shaped as `v<marketing>+<build>`, for example `v0.1.12+12`.
- Every release contains the fixed asset `Murmure.app.zip`; `Murmure.app.zip.sha256` remains available for manual verification.
- The app uses GitHub's public latest-release endpoint without an account or token.
- The app accepts only HTTPS metadata and download URLs for the fixed repository and asset.
- The app verifies GitHub's `sha256:<digest>` release-asset digest before extraction.
- The bundle identifier remains `ai.pivotstudio.murmur-youtube`.
- Release bundles must use the existing stable certificate-backed local signing identity. Ad-hoc or differently signed builds fail closed for hosted updates.
- No Apple Developer ID or notarization is claimed. First install still requires the documented Control-click Open flow.
- The current Settings card layout, spacing, typography, colors, and button styles are locked. Only update-specific labels and status copy may change.
- Existing `make stage-update` local staging remains a developer fallback.
- No audio, transcript, dictionary, history, or external-drive data participates in an update.
- The updater may remove only temporary files that it created inside its Application Support update inbox. It must never touch unrelated external-drive files.

## User workflow

1. Settings initially shows the installed version and a `Check for updates` button.
2. Pressing the button checks the latest stable GitHub Release.
3. If the installed version is current, the card explicitly reports `Murmure is up to date.`
4. If a newer release exists, Murmure downloads and fully prepares it before showing `Install and relaunch`.
5. Pressing `Install and relaunch` launches the nested helper, exits the current app, replaces `/Applications/Murmure.app`, preserves a rollback copy, and opens the new version.
6. If GitHub is unavailable, a valid newer local staged update can still be offered. Otherwise the app shows a concise recoverable error and leaves the installed app untouched.

## Data shapes first

The caller-visible update state stays small:

```swift
public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(UpdateManifest)
    case installing
    case failed(String)
}
```

`UpdateManifest` remains the validated handoff record already shared with the helper. GitHub response details do not cross the SwiftUI seam.

The hosted-release contract is represented inside `MurmurUpdateCore`:

```swift
public struct HostedReleaseCandidate: Equatable, Sendable {
    public let releaseID: Int64
    public let tag: String
    public let version: AppVersion
    public let archiveURL: URL
    public let archiveSize: Int64
    public let archiveSHA256: String
}
```

`GitHubReleaseContract` decodes the GitHub response, requires the exact fixed asset once, validates its HTTPS repository path, parses the version tag, validates the digest, and returns either a newer candidate or `nil`.

## Deep-module interface

Settings continues to call one concrete observable module:

```swift
@MainActor
@Observable
final class AppUpdateCoordinator {
    private(set) var state: UpdateState
    let currentVersion: AppVersion

    func refreshStagedUpdate()
    func checkForUpdates() async
    func installAvailableUpdate()
}
```

`refreshStagedUpdate()` is a local-only launch refresh. `checkForUpdates()` owns the complete hosted check and preparation and is awaited from a short button `Task`. `installAvailableUpdate()` owns the already-validated helper handoff. SwiftUI never learns URLs, hashes, ZIP entries, signing requirements, inbox paths, or process arguments.

The hosted implementation sits behind one deeper entry point:

```swift
public struct GitHubReleaseUpdater: Sendable {
    public func stageLatestUpdate(
        newerThan currentVersion: AppVersion,
        installedBundleURL: URL,
        inboxURL: URL
    ) async throws -> UpdateManifest?
}
```

Its production adapter uses `URLSession`. Its tests use a scripted transport. This is a real seam because GitHub is a true external dependency and the scripted adapter drives the same updater interface.

## Release discovery contract

- Request `GET https://api.github.com/repos/filipego/murmure/releases/latest`.
- Send `Accept: application/vnd.github+json`, a fixed `User-Agent`, and GitHub API version `2022-11-28`.
- Treat HTTP 404 as `no published release`, not a malformed update.
- Treat 403 or 429 as a rate-limit/network failure with no immediate retry loop.
- Reject drafts and prereleases even though the latest endpoint normally excludes them.
- Require tag `v<marketing>+<positive build>`.
- Require exactly one uploaded asset named `Murmure.app.zip`.
- Require `size` from 1 byte through 536,870,912 bytes.
- Require digest `sha256:` followed by exactly 64 hexadecimal characters.
- Require the asset URL to be HTTPS and to begin with `/filipego/murmure/releases/download/<tag>/Murmure.app.zip` on `github.com`.
- Do not download equal versions or downgrades.

## Download, archive, and staging contract

1. Create a mode-0700 transaction directory below the update inbox.
2. Download the archive only into that transaction directory.
3. Require a successful HTTP response, the advertised byte count, and the advertised SHA-256 digest.
4. Open the archive with ZIPFoundation `0.9.20`.
5. Before extraction, reject empty archives, absolute paths, `..` components, NULs, symlinks, more than 10,000 entries, more than 1 GiB declared expanded size, or any top-level path other than `Murmure.app`.
6. Extract below the transaction directory using ZIPFoundation's containment-safe implementation.
7. Require exactly one `Murmure.app` bundle.
8. Validate its identifier, executable, and full `AppVersion`; the bundle version must equal the release tag version and be strictly newer than the installed version.
9. Validate the full code seal, nested code, and signing continuity before publishing the manifest.
10. Write `manifest.json` atomically only after every validation succeeds.
11. On failure, remove only that newly created transaction directory. Never replace the prior validated manifest or bundle.

## Signing and authenticity

The GitHub digest proves that the downloaded bytes match GitHub's release metadata. It does not independently authenticate the publisher because both are controlled by the same GitHub account.

Publisher continuity is therefore also enforced with macOS code signing:

- The expected release designated requirement is the stable bundle identifier plus certificate root SHA-1 `dd1175e05550d5ff2ac47ca8621caf97be7ab707`.
- Validate all architectures, sealed resources, nested code, strict bundle rules, and restricted symlinks with Security.framework.
- Require both the installed bundle and staged bundle to satisfy the expected release requirement.
- Require the staged bundle to satisfy the installed bundle's designated requirement.
- Accept the specific certificate-not-trusted result only when the exact pinned certificate and installed/staged requirement checks match. This permits friends to validate the self-signed local release certificate without adding it to their system trust store. All content, resource, requirement, and signature failures still fail closed.
- Re-run the same validation in `MurmurUpdateHelper` immediately before replacement.

The release Makefile target must refuse to publish an ad-hoc build or a bundle whose designated requirement differs from the pinned release requirement. The private signing key stays in the developer's Keychain and is never committed or uploaded.

## Installation and rollback

The current helper remains the installation module:

1. The coordinator revalidates inbox containment, manifest version, bundle structure, and signature continuity.
2. It resolves only `Contents/Helpers/MurmurUpdateHelper` from the running bundle.
3. It launches the helper with structured process arguments and terminates only after launch succeeds.
4. The helper waits for the parent process to exit.
5. The helper validates source and destination again.
6. `BundleReplacer` copies and validates a destination-sibling temporary bundle before moving the installed bundle away.
7. It keeps the previous installed bundle at a unique backup path and restores it if replacement fails.
8. It opens the new destination. A retained backup gives an explicit manual recovery path if the new version launches but later fails.

This release does not add a watchdog or health-token protocol. That would be a separate subsystem and is not required to make the GitHub update button genuine, integrity-checked, and rollback-safe for replacement failures.

## UI preservation

The card keeps its existing structure and tokens. Approved copy changes are limited to:

- `Local update` to `Updates`.
- `Check for staged update` to `Check for updates`.
- Local-only status copy to GitHub-aware checking, up-to-date, available, installing, and failure copy.
- Accessibility labels and hints updated to describe GitHub Releases and validation honestly.

No other Settings view presentation changes are allowed.

## Release and proof plan

1. Build and directly install an updater-aware `0.1.11 (11)` using the stable signing identity.
2. Bump the release bundle to `0.1.12 (12)`.
3. Run the complete Swift suite, bundle validation, signing validation, and archive checksum verification.
4. Merge and push the final source to `main`.
5. Publish GitHub Release `v0.1.12+12` with `Murmure.app.zip`, `Murmure.app.zip.sha256`, and install notes.
6. From the installed `0.1.11` app, press the real Settings button, prepare the hosted `0.1.12` update, install, and relaunch.
7. Prove `/Applications/Murmure.app` is `0.1.12 (12)`, has the pinned signature, retained Microphone and Accessibility grants, and matches the published release artifact.
8. Compare the final Settings surface with the captured `0.1.10` baseline and confirm no layout/style delta beyond the approved copy.

## Non-goals

- Apple notarization or Developer ID enrollment.
- Automatic background installation.
- Release channels, prereleases, deltas, or release notes in the app.
- Authentication to GitHub from the app.
- GitHub Actions signing or uploading the private certificate.
- Windows self-update. The Windows app remains separately packaged and unverified on physical hardware.
