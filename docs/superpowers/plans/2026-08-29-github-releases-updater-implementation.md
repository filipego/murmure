# GitHub Releases Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Murmure's local-only update check with a tested GitHub Releases pipeline that downloads, verifies, stages, installs, and relaunches a newer signed app while preserving the existing local fallback and Settings presentation.

**Architecture:** Keep `AppUpdateCoordinator` as the small SwiftUI-facing module. Put GitHub parsing, transport, hashing, safe ZIP extraction, bundle validation, and code-signature continuity inside `MurmurUpdateCore`, then reuse the existing manifest and nested helper handoff. A pinned ZIPFoundation release handles entry-aware extraction; Security.framework anchors releases to the existing local signing certificate.

**Tech Stack:** Swift 6.2, Swift Testing/XCTest, Foundation `URLSession`, CryptoKit SHA-256, Security.framework Code Signing Services, ZIPFoundation 0.9.20, SwiftUI/Observation, GitHub Releases REST API.

## Global Constraints

- Repository is exactly `filipego/murmure`; endpoint is exactly `https://api.github.com/repos/filipego/murmure/releases/latest`.
- Stable tag format is exactly `v<marketing>+<build>` and the fixed release asset is exactly `Murmure.app.zip`.
- Bundle identifier remains exactly `ai.pivotstudio.murmur-youtube`.
- Release certificate root SHA-1 remains exactly `dd1175e05550d5ff2ac47ca8621caf97be7ab707`.
- ZIPFoundation is pinned exactly to `0.9.20`.
- Hosted updates fail closed for ad-hoc, invalid, tampered, or differently signed bundles.
- `make stage-update` remains compatible as a local fallback.
- No Apple Developer ID or notarization is claimed.
- Settings layout, spacing, typography, colors, sizing, and button styles remain unchanged. Only approved update copy changes.
- Update code never reads, moves, or deletes audio, transcripts, history, dictionary, settings, or unrelated external-drive data.
- Only updater-created temporary paths below the Application Support update inbox may be removed.
- Use `make` for app builds. Use an explicit scratch path for Swift tests.
- Use TDD: every production behavior begins with a test that is run and observed failing for the expected reason.

---

## File map

- Create `Sources/MurmurUpdateCore/GitHubReleaseContract.swift`: pure GitHub JSON, version-tag, asset URL, size, and digest contract.
- Create `Sources/MurmurUpdateCore/ReleaseCodeSignatureValidator.swift`: pinned certificate and installed/staged code-signature continuity checks.
- Create `Sources/MurmurUpdateCore/GitHubReleaseUpdater.swift`: transport, download, SHA-256, safe ZIP staging, and atomic manifest publication.
- Modify `Sources/MurmurUpdateCore/UpdateCore.swift`: add `upToDate` state and make replacement pre-copy before moving the destination.
- Modify `Sources/MurmurYouTube/Support/AppUpdateCoordinator.swift`: hosted async check, local fallback, install-time signature revalidation.
- Modify `Sources/MurmurYouTube/UI/SettingsWindow.swift`: update-only copy and async button action, with the current card presentation preserved.
- Modify `Sources/MurmurUpdateHelper/main.swift`: re-run release signature continuity immediately before replacement.
- Modify `Package.swift`: pin ZIPFoundation and link it only to `MurmurUpdateCore`.
- Create `Tests/MurmurUpdateCoreTests/GitHubReleaseContractTests.swift`: pure release contract coverage.
- Create `Tests/MurmurUpdateCoreTests/GitHubReleaseUpdaterTests.swift`: real temporary ZIP/hash/filesystem staging coverage with scripted transport.
- Create `Tests/MurmurUpdateCoreTests/ReleaseCodeSignatureValidatorTests.swift`: fail-closed status policy and real signed-bundle integration hook.
- Create `Tests/MurmurYouTubeTests/AppUpdateCoordinatorTests.swift`: observable hosted/local/check/install behavior.
- Modify `Tests/MurmurUpdateCoreTests/UpdateCoreTests.swift`: pre-copy replacement regression.
- Modify `Makefile`: repeatable tests, release signing gate, release tag, and friend artifacts.
- Modify `Resources/Info.plist`: updater-aware proof build `0.1.11 (11)`, final hosted release `0.1.12 (12)`.
- Modify `README.md` and generated `dist/INSTALL.md`: first install and subsequent GitHub update instructions.
- Rebuild `dist/Murmure.app.zip` and `dist/Murmure.app.zip.sha256`: exact published artifacts.

---

### Task 1: Define and prove the GitHub release contract

**Files:**
- Create: `Sources/MurmurUpdateCore/GitHubReleaseContract.swift`
- Create: `Tests/MurmurUpdateCoreTests/GitHubReleaseContractTests.swift`
- Modify: `Sources/MurmurUpdateCore/UpdateCore.swift`

**Interfaces:**
- Consumes: existing `AppVersion` comparison.
- Produces: `HostedReleaseCandidate`, `GitHubReleaseContract.candidate(from:newerThan:)`, `GitHubReleaseContractError`, and `UpdateState.upToDate`.

- [ ] **Step 1: Write failing happy-path and current-version tests**

Create tests that express the public contract before creating the production type:

```swift
import Foundation
import Testing
@testable import MurmurUpdateCore

@Suite("GitHub release contract")
struct GitHubReleaseContractTests {
    @Test("selects the exact signed archive from a newer stable release")
    func selectsNewerRelease() throws {
        let data = Data(Self.releaseJSON(
            tag: "v0.1.12+12",
            assetName: "Murmure.app.zip",
            assetURL: "https://github.com/filipego/murmure/releases/download/v0.1.12+12/Murmure.app.zip",
            size: 12_345,
            digest: "sha256:" + String(repeating: "a", count: 64)
        ).utf8)

        let result = try GitHubReleaseContract.candidate(
            from: data,
            newerThan: AppVersion(marketing: "0.1.11", build: 11)
        )

        #expect(result?.version == AppVersion(marketing: "0.1.12", build: 12))
        #expect(result?.archiveSize == 12_345)
        #expect(result?.archiveSHA256 == String(repeating: "a", count: 64))
    }

    @Test("does not download an equal release")
    func ignoresEqualRelease() throws {
        let data = Data(Self.releaseJSON(tag: "v0.1.12+12").utf8)
        #expect(try GitHubReleaseContract.candidate(
            from: data,
            newerThan: AppVersion(marketing: "0.1.12", build: 12)
        ) == nil)
    }
}
```

The test helper must emit `id`, `tag_name`, `draft`, `prerelease`, and an `assets` array with `name`, `state`, `size`, `digest`, and `browser_download_url` so every decoded field is intentional.

- [ ] **Step 2: Run the focused tests and observe RED**

Run:

```bash
swift test --scratch-path /private/tmp/murmure-github-updater-build --filter GitHubReleaseContractTests
```

Expected: compilation fails because `GitHubReleaseContract` and `HostedReleaseCandidate` do not exist.

- [ ] **Step 3: Implement the minimal data shapes and happy path**

Implement these exact shapes:

```swift
public struct HostedReleaseCandidate: Equatable, Sendable {
    public let releaseID: Int64
    public let tag: String
    public let version: AppVersion
    public let archiveURL: URL
    public let archiveSize: Int64
    public let archiveSHA256: String
}

public enum GitHubReleaseContract {
    public static func candidate(
        from data: Data,
        newerThan currentVersion: AppVersion
    ) throws -> HostedReleaseCandidate?
}
```

The decoder remains private. Parse tags by splitting the final `+` into a positive integer build and feeding the prefix through `AppVersion`. Lowercase the accepted digest after requiring `sha256:` plus 64 hex characters.

- [ ] **Step 4: Run focused tests and observe GREEN**

Run the same focused command. Expected: both tests pass.

- [ ] **Step 5: Add one failing test per rejection class**

Add separate tests for malformed tag, draft, prerelease, missing asset, duplicate exact asset, non-uploaded state, zero/oversized asset, missing/malformed digest, HTTP URL, wrong host, wrong owner/repository path, wrong tag in path, and wrong filename. Each test asserts the specific `GitHubReleaseContractError` case.

- [ ] **Step 6: Run rejection tests and observe RED**

Expected: at least the first unsupported rejection passes incorrectly or reports the wrong error.

- [ ] **Step 7: Implement strict validation and `UpdateState.upToDate`**

Add stable error cases without embedding untrusted server text in user-facing messages. Extend `UpdateState` with exactly `case upToDate` and update every exhaustive switch compile error without changing UI copy yet.

- [ ] **Step 8: Run focused and complete update-core tests**

Run:

```bash
swift test --scratch-path /private/tmp/murmure-github-updater-build --filter GitHubReleaseContractTests
swift test --scratch-path /private/tmp/murmure-github-updater-build --filter MurmurUpdateCoreTests
```

Expected: all release-contract and existing update-core tests pass.

- [ ] **Step 9: Commit Task 1**

```bash
git add Sources/MurmurUpdateCore/GitHubReleaseContract.swift Sources/MurmurUpdateCore/UpdateCore.swift Tests/MurmurUpdateCoreTests/GitHubReleaseContractTests.swift
git commit -m "feat(updates): define GitHub release contract"
```

---

### Task 2: Download, verify, safely extract, and stage a hosted update

**Files:**
- Modify: `Package.swift`
- Create: `Sources/MurmurUpdateCore/ReleaseCodeSignatureValidator.swift`
- Create: `Sources/MurmurUpdateCore/GitHubReleaseUpdater.swift`
- Create: `Tests/MurmurUpdateCoreTests/ReleaseCodeSignatureValidatorTests.swift`
- Create: `Tests/MurmurUpdateCoreTests/GitHubReleaseUpdaterTests.swift`

**Interfaces:**
- Consumes: `HostedReleaseCandidate`, `GitHubReleaseContract`, `BundleValidator`, `UpdateManifest`.
- Produces: `GitHubReleaseUpdater.stageLatestUpdate(newerThan:installedBundleURL:inboxURL:)`, scripted/live transport seam, and `ReleaseCodeSignatureValidator.validateReplacement(stagedBundleURL:installedBundleURL:)`.

- [ ] **Step 1: Pin ZIPFoundation and write the first failing staging test**

Add exactly:

```swift
.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
```

and add `.product(name: "ZIPFoundation", package: "ZIPFoundation")` only to `MurmurUpdateCore`.

The first test builds a real temporary `Murmure.app`, archives it with ZIPFoundation, computes its SHA-256, scripts a metadata response plus archive download, injects a recording signature validator, and calls:

```swift
let manifest = try await updater.stageLatestUpdate(
    newerThan: AppVersion(marketing: "0.1.11", build: 11),
    installedBundleURL: installed,
    inboxURL: inbox
)

#expect(manifest?.version == AppVersion(marketing: "0.1.12", build: 12))
#expect(manifest?.bundleIdentifier == murmurBundleIdentifier)
#expect(manifest.map { $0.stagedBundleURL.path.hasPrefix(inbox.path + "/") } == true)
#expect(await signatureRecorder.calls == 1)
```

- [ ] **Step 2: Run the focused test and observe RED**

Run:

```bash
swift test --scratch-path /private/tmp/murmure-github-updater-build --filter GitHubReleaseUpdaterTests
```

Expected: compilation fails because `GitHubReleaseUpdater` and its injected seams do not exist.

- [ ] **Step 3: Implement the transport seam and metadata request**

Use these internal testable shapes:

```swift
package struct UpdateHTTPData: Sendable {
    package let data: Data
    package let statusCode: Int
    package let finalURL: URL
}

package struct UpdateHTTPDownload: Sendable {
    package let fileURL: URL
    package let statusCode: Int
    package let finalURL: URL
}

package protocol UpdateTransport: Sendable {
    func data(for request: URLRequest) async throws -> UpdateHTTPData
    func download(for request: URLRequest) async throws -> UpdateHTTPDownload
}
```

The live adapter uses `URLSession.data(for:)` and `URLSession.download(for:)`. The updater's public initializer assembles the live transport. A package-scoped initializer accepts transport and signature closure for tests.

Treat metadata 404 as `nil`; accept only 200 for metadata and archive. Build the exact headers from the design spec.

- [ ] **Step 4: Implement minimal verified staging and observe GREEN**

After discovery, move the downloaded file into the transaction directory, compare its file size, stream it through `CryptoKit.SHA256`, and compare the lowercase digest before opening the ZIP. Preflight every entry, extract below the transaction directory, validate the bundle/version, invoke the signature validator, create the ISO-8601 `UpdateManifest`, and write `manifest.json` with `.atomic` only at the end.

Run the focused test. Expected: the happy path passes.

- [ ] **Step 5: Write failing safety tests**

Add independent tests proving:

- 404 returns `nil` without a download request.
- digest mismatch leaves a pre-existing manifest byte-for-byte unchanged.
- advertised/downloaded size mismatch fails before extraction.
- wrong bundle version fails after extraction but before signature publication.
- a signature failure leaves the old manifest unchanged.
- empty archive, absolute path, parent traversal, NUL, symlink, extra top-level root, excessive entry count, and excessive expanded size are rejected.
- a failed transaction removes only its UUID directory and does not remove a sibling sentinel file.

- [ ] **Step 6: Run safety tests and observe RED**

Expected: newly added unsupported cases fail for the named behavior rather than test setup.

- [ ] **Step 7: Implement the safe archive policy**

Use ZIPFoundation's entry metadata. Split paths on `/`, reject empty path components except a final directory separator, reject `.` and `..`, require the first component to be `Murmure.app`, reject `.symlink`, cap entries at 10,000, sum declared uncompressed sizes with overflow checking, and cap the sum at 1,073,741,824 bytes. Require exactly one extracted top-level bundle.

- [ ] **Step 8: Write failing signature-policy tests**

Test a pure decision helper that accepts `errSecSuccess`, accepts certificate-not-trusted only with pinned requirement and certificate matches, and rejects every other OSStatus or mismatch. Add a machine integration test that is skipped when the stable signed fixture is unavailable and otherwise validates `/Applications/Murmure.app` against a freshly built bundle.

- [ ] **Step 9: Implement the Security.framework validator**

Define:

```swift
public let murmurReleaseCertificateRootSHA1 = "dd1175e05550d5ff2ac47ca8621caf97be7ab707"

public enum ReleaseCodeSignatureValidator {
    public static func validateReplacement(
        stagedBundleURL: URL,
        installedBundleURL: URL
    ) throws
}
```

Create `SecStaticCode` values for both bundles. Compile the pinned requirement and copy the installed bundle's designated requirement. Validate each bundle using check-all-architectures, nested-code, strict-validation, restricted-symlink, and app-like flags. Compare the root certificate DER SHA-1 with the pinned value for both bundles. Require the staged bundle to satisfy the installed designated requirement. Accept only success or the explicitly tested untrusted-certificate result after all pinned comparisons succeed.

- [ ] **Step 10: Run focused and complete tests**

Run:

```bash
swift test --scratch-path /private/tmp/murmure-github-updater-build --filter GitHubReleaseUpdaterTests
swift test --scratch-path /private/tmp/murmure-github-updater-build --filter ReleaseCodeSignatureValidatorTests
swift test --scratch-path /private/tmp/murmure-github-updater-build
```

Expected: all tests pass. Pre-existing compiler warnings may be reported separately; no new updater warning is accepted.

- [ ] **Step 11: Commit Task 2**

```bash
git add Package.swift Package.resolved Sources/MurmurUpdateCore/GitHubReleaseUpdater.swift Sources/MurmurUpdateCore/ReleaseCodeSignatureValidator.swift Tests/MurmurUpdateCoreTests/GitHubReleaseUpdaterTests.swift Tests/MurmurUpdateCoreTests/ReleaseCodeSignatureValidatorTests.swift
git commit -m "feat(updates): verify and stage hosted releases"
```

---

### Task 3: Connect the real button and harden installation handoff

**Files:**
- Modify: `Sources/MurmurYouTube/Support/AppUpdateCoordinator.swift`
- Modify: `Sources/MurmurYouTube/UI/SettingsWindow.swift`
- Modify: `Sources/MurmurUpdateHelper/main.swift`
- Modify: `Sources/MurmurUpdateCore/UpdateCore.swift`
- Create: `Tests/MurmurYouTubeTests/AppUpdateCoordinatorTests.swift`
- Modify: `Tests/MurmurUpdateCoreTests/UpdateCoreTests.swift`
- Modify: `Resources/Info.plist`

**Interfaces:**
- Consumes: `GitHubReleaseUpdater`, `ReleaseCodeSignatureValidator`, existing helper argv.
- Produces: `refreshStagedUpdate()`, async `checkForUpdates()`, signature-checked `installAvailableUpdate()`, updater-aware proof build `0.1.11 (11)`.

- [ ] **Step 1: Write failing coordinator state tests**

Inject this hosted seam into the coordinator's internal initializer:

```swift
typealias HostedUpdateStager = @Sendable (
    AppVersion,
    URL,
    URL
) async throws -> UpdateManifest?
```

Add `@MainActor` tests that assert:

```swift
await coordinator.checkForUpdates()
#expect(coordinator.state == .upToDate)
```

when hosted staging returns `nil`; `.available(manifest)` when it returns a newer manifest; a valid local staged update when hosted staging throws; and `.failed` when both hosted and local paths fail. Record state inside the injected closure to prove `.checking` is visible before awaiting the result.

- [ ] **Step 2: Run the coordinator tests and observe RED**

Run:

```bash
swift test --scratch-path /private/tmp/murmure-github-updater-build --filter AppUpdateCoordinatorTests
```

Expected: compilation fails because the hosted seam, `checkForUpdates()`, and `.upToDate` handling do not exist.

- [ ] **Step 3: Refactor local validation and implement the hosted check**

Extract the current manifest reading/path containment/bundle validation into `validatedStagedManifest() throws -> UpdateManifest?`. `refreshStagedUpdate()` uses it without networking. `checkForUpdates()` guards against `.checking`/`.installing`, sets `.checking`, awaits the hosted stager, prefers a returned hosted manifest, otherwise checks local staging, then sets `.upToDate`. On hosted error, use a valid newer local manifest before setting `.failed`.

The production stager constructs `GitHubReleaseUpdater()` and calls its deep interface. Do not put URLSession, JSON, SHA, or ZIP code in the coordinator.

- [ ] **Step 4: Run coordinator tests and observe GREEN**

Expected: all coordinator tests pass.

- [ ] **Step 5: Write failing install-order and replacement regression tests**

Coordinator test: inject a recording signature validator and helper launcher; assert the order is `signature`, `helper`, `terminate`. A signature failure must assert no helper launch and no termination.

Update-core regression: create a valid installed bundle and a staged bundle whose copy destination cannot be completed; assert the installed destination marker remains present. The test name is `testBundleReplacerCopiesBeforeMovingInstalledBundle`.

- [ ] **Step 6: Run the new tests and observe RED**

Expected: the signature ordering test fails because install does not validate signing, and the replacement regression exposes the current move-before-copy order.

- [ ] **Step 7: Harden coordinator, helper, and replacer**

Call `ReleaseCodeSignatureValidator.validateReplacement` in the coordinator immediately before resolving/launching the helper. Call it again in `MurmurUpdateHelper` after structural validation and before waiting/replacement. In `BundleReplacer`, copy the staged bundle to the destination-sibling temporary path and validate that copy before moving the destination to its unique backup. Preserve the existing best-effort rollback if the final move fails.

- [ ] **Step 8: Change only approved Update card copy**

Keep every layout and design modifier unchanged. Make only these behavioral/copy edits:

```swift
.task { updates?.refreshStagedUpdate() }

Button("Check for updates") {
    Task { await coordinator.checkForUpdates() }
}
.buttonStyle(.bordered)
```

Change the title to `Updates`; add `upToDate` status `Murmure is up to date.`; change checking copy to `Checking GitHub Releases and preparing any update…`; and update accessibility label/hint to describe a verified GitHub release. Disable the check button while checking or installing without changing its style.

- [ ] **Step 9: Set the proof build version and run all tests**

Change `Resources/Info.plist` to exactly `0.1.11` and build `11`. Run:

```bash
swift test --scratch-path /private/tmp/murmure-github-updater-build
make app
```

Expected: the full suite passes and `make app` creates the signed proof bundle.

- [ ] **Step 10: Commit Task 3**

```bash
git add Sources/MurmurYouTube/Support/AppUpdateCoordinator.swift Sources/MurmurYouTube/UI/SettingsWindow.swift Sources/MurmurUpdateHelper/main.swift Sources/MurmurUpdateCore/UpdateCore.swift Tests/MurmurYouTubeTests/AppUpdateCoordinatorTests.swift Tests/MurmurUpdateCoreTests/UpdateCoreTests.swift Resources/Info.plist
git commit -m "feat(updates): connect Settings to GitHub Releases"
```

The controller now pauses implementation ownership while the parent builds and directly installs this exact `0.1.11 (11)` commit as the updater-aware proof surface.

---

### Task 4: Make signed releases repeatable and document the friend workflow

**Files:**
- Modify: `Makefile`
- Modify: `README.md`
- Modify: `Resources/Info.plist`
- Rebuild: `dist/Murmure.app.zip`
- Rebuild: `dist/Murmure.app.zip.sha256`
- Rebuild: `dist/INSTALL.md`

**Interfaces:**
- Consumes: stable signing identity, pinned release requirement, fixed asset convention.
- Produces: `make test`, `make release`, final `0.1.12 (12)` bundle, friend download link, and exact GitHub Release assets.

- [ ] **Step 1: Add repeatable test and release targets**

Add `test` to `.PHONY` and run the full suite through an out-of-tree scratch path. Add `release: share` that:

1. fails if `SIGN_ID` is `-`;
2. runs `codesign --verify --deep --strict` on the bundle;
3. extracts the designated requirement and requires the exact identifier and certificate-root hash;
4. verifies the `.sha256` sidecar with `shasum -a 256 -c`;
5. prints the exact tag `v$(VERSION)+$(BUILD_NUMBER)` and three asset paths without creating or mutating a GitHub release.

Do not put credentials or private key material in the Makefile.

- [ ] **Step 2: Update the friend documentation**

Replace repository-blob installation as the recommendation with:

```markdown
Download the latest fixed release asset:
https://github.com/filipego/murmure/releases/latest/download/Murmure.app.zip
```

Explain that the first install still needs Control-click Open plus Microphone and Accessibility grants. Explain that subsequent versions use Settings → Updates → Check for updates → Install and relaunch. State that the app makes an unauthenticated request only to the fixed public GitHub release endpoint and sends no dictation data.

Update the Codex copy-paste prompt to prefer the latest release asset and use source build only as a fallback. Keep the warning not to share user data or signing keys.

- [ ] **Step 3: Set final release version**

Change `Resources/Info.plist` to exactly `0.1.12` and build `12`.

- [ ] **Step 4: Run release verification**

Run:

```bash
make test
make release
```

Expected: all tests pass; the app and nested helper verify; the release-signing gate reports the pinned requirement; the archive checksum verifies; the printed tag is `v0.1.12+12`.

- [ ] **Step 5: Inspect secrets and generated artifacts**

Run:

```bash
git status --short
git diff --check
git ls-files | rg '(\.p12|\.mobileprovision|\.env$|private[-_]?key|credentials)'
shasum -a 256 -c dist/Murmure.app.zip.sha256
```

Expected: no credentials or signing material are tracked; the checksum passes; only intended updater, documentation, version, and artifact files changed.

- [ ] **Step 6: Commit Task 4**

```bash
git add Makefile README.md Resources/Info.plist dist/INSTALL.md dist/Murmure.app.zip dist/Murmure.app.zip.sha256 docs/superpowers/specs/2026-08-29-github-releases-updater-design.md docs/superpowers/plans/2026-08-29-github-releases-updater-implementation.md
git commit -m "release: prepare Murmure 0.1.12 updater"
```

---

## Controller release checklist

- [ ] Generate one review package per task from its recorded base commit and obtain both spec-compliance and code-quality approval.
- [ ] Run a broad two-axis review against this spec and the repository `AGENTS.md`; resolve every Critical/Important finding.
- [ ] Re-run `make test`, `make release`, `git diff --check`, `codesign --verify --deep --strict`, and checksum verification.
- [ ] Merge the feature branch to `main` and push `main` without force.
- [ ] Publish GitHub Release `v0.1.12+12` from final `main` with `dist/Murmure.app.zip`, `dist/Murmure.app.zip.sha256`, and `dist/INSTALL.md`.
- [ ] Confirm the public latest-release API returns the exact tag, fixed asset, size, and SHA-256 digest.
- [ ] In the installed updater-aware `0.1.11 (11)` app, use the real Settings button to check, stage, install, and relaunch `0.1.12 (12)`.
- [ ] Verify `/Applications/Murmure.app` version/build, bundle ID, designated requirement, nested helper, process, Microphone permission, Accessibility permission, and retained rollback bundle.
- [ ] Compare the installed Settings screenshot/AX tree to the captured baseline. Approved copy is the only visible delta.
- [ ] Mark the explicit goal complete only after the published and installed surfaces pass.
