# Live Text Insertion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in Apple transcription mode that updates a verified destination field while the user speaks and safely reconciles it with Murmure's processed final text.

**Architecture:** Persist `TextInsertionTiming` as user intent. A deep `LiveTextInsertionSession` module owns all live destination state behind `render`, `finalize`, and `cancel`; an accessibility adapter performs verified range replacement. `DictationController` routes Apple snapshots through that module and retains the existing one-shot injector as the safe fallback.

**Tech Stack:** Swift 6.2, SwiftUI, macOS 26 SpeechAnalyzer, macOS Accessibility, Swift Testing, existing Murmure localization catalog.

## Global Constraints

- Existing installations and missing settings values default to `afterSpeaking`.
- Live typing is effective only for resolved Apple transcription with Compare Mode off.
- Never select, delete, or replace text unless the currently observed range contains exactly the text Murmure recorded as owned.
- Existing one-shot Accessibility and pasteboard insertion remains unchanged for after-finish dictation.
- Automatic language, Parakeet, Compare Mode, and Command Mode never attempt live insertion.
- Every new visible string has English, French, and Spanish catalog entries.
- Only one picker and one explanatory/status line may be added to Settings > Dictation. All other visual presentation stays unchanged.
- No cloud service, subscription, paid API, or new dependency.

---

### Task 1: Persist insertion timing and define effective behavior

**Files:**
- Modify: `Sources/MurmurYouTube/Support/Settings.swift`
- Modify: `Tests/MurmurYouTubeTests/TranscriptionLanguageTests.swift`

**Interfaces:**
- Produces: `enum TextInsertionTiming: String, CaseIterable, Codable, Sendable`
- Produces: `Settings.textInsertionTiming`
- Produces: `SettingsSnapshot.resolvedTextInsertionTiming`

- [ ] **Step 1: Write the failing compatibility tests**

Add tests that decode a legacy snapshot without `textInsertionTiming` and expect `.afterSpeaking`, then decode and re-encode `"textInsertionTiming":"whileSpeaking"` and expect `.whileSpeaking`.

```swift
@Test("legacy settings type only after speaking")
func legacyInsertionTiming() throws {
    let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: legacySettingsJSON)
    #expect(snapshot.resolvedTextInsertionTiming == .afterSpeaking)
}

@Test("live insertion timing round trips")
func liveInsertionTimingRoundTrips() throws {
    let data = Data(legacySettingsJSONString
        .dropLast()
        .appending(#",\"textInsertionTiming\":\"whileSpeaking\"}"#).utf8)
    let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)
    #expect(snapshot.resolvedTextInsertionTiming == .whileSpeaking)
    let encoded = try JSONEncoder().encode(snapshot)
    #expect(String(decoding: encoded, as: UTF8.self).contains("whileSpeaking"))
}
```

- [ ] **Step 2: Run the focused tests and confirm RED**

Run: `make test TEST_FILTER=TranscriptionLanguageTests`

Expected: compilation fails because `resolvedTextInsertionTiming` and `TextInsertionTiming` do not exist.

- [ ] **Step 3: Add the setting and migration default**

Implement the enum and optional snapshot field:

```swift
enum TextInsertionTiming: String, CaseIterable, Codable, Sendable {
    case afterSpeaking
    case whileSpeaking
}

struct SettingsSnapshot: Codable {
    // existing fields
    let textInsertionTiming: TextInsertionTiming?
    var resolvedTextInsertionTiming: TextInsertionTiming { textInsertionTiming ?? .afterSpeaking }
}
```

Add `Settings.textInsertionTiming`, `Keys.textInsertionTiming`, hydration, local defaults mirroring, and external snapshot persistence. Use `.afterSpeaking` whenever no value exists.

- [ ] **Step 4: Run the focused tests and confirm GREEN**

Run: `make test TEST_FILTER=TranscriptionLanguageTests`

Expected: all `TranscriptionLanguageTests` pass.

- [ ] **Step 5: Commit the settings slice**

```bash
git add Sources/MurmurYouTube/Support/Settings.swift Tests/MurmurYouTubeTests/TranscriptionLanguageTests.swift
git commit -m "feat: persist live typing preference"
```

### Task 2: Build the verified owned-range module

**Files:**
- Create: `Sources/MurmurYouTube/Core/LiveTextInsertionSession.swift`
- Create: `Tests/MurmurYouTubeTests/LiveTextInsertionSessionTests.swift`
- Modify: `Sources/MurmurYouTube/Core/TextInjector.swift`

**Interfaces:**
- Produces: `@MainActor final class LiveTextInsertionSession`
- Produces: `render(_:) async`, `finalize(_:) async -> LiveTextFinalization`, and `cancel() async`
- Produces: `LiveTextTargetCapturing` and `LiveTextTarget` seams with production Accessibility adapters and test fakes
- Consumes: the existing pasteboard preservation and Command-V behavior from `TextInjector`

- [ ] **Step 1: Write failing state-machine tests**

Cover these observable cases through a fake `LiveTextTarget`:

```swift
@Test("successive snapshots replace only the owned range")
func replacesOwnedRange() async {
    let target = FakeLiveTextTarget(selection: NSRange(location: 4, length: 0), text: "")
    let session = LiveTextInsertionSession(capture: target.capture)
    await session.render("hel")
    await session.render("hello")
    #expect(target.replacements.map(\.replacement) == ["hel", "hello"])
    #expect(target.documentText == "hello")
}

@Test("caret movement stops mutation and prevents duplicate final insertion")
func caretMovementAbandonsOwnedText() async {
    // Render one partial, move the fake caret, then finalize.
    #expect(await session.finalize("Hello.") == .retainedInHistoryOnly)
    #expect(target.documentText == "hel")
}

@Test("unavailable target before first mutation uses one shot final insertion")
func unavailableTargetFallsBackCleanly() async {
    #expect(await session.finalize("Hello.") == .useOneShotInsertion)
}

@Test("cancel restores the original selection only while ownership is verified")
func verifiedCancelRollsBack() async {
    await session.render("temporary")
    await session.cancel()
    #expect(target.documentText == originalText)
}
```

- [ ] **Step 2: Run the focused tests and confirm RED**

Run: `make test TEST_FILTER=LiveTextInsertionSessionTests`

Expected: compilation fails because the module does not exist.

- [ ] **Step 3: Implement the deep live-insertion module**

Use this narrow external interface:

```swift
enum LiveTextFinalization: Equatable, Sendable {
    case alreadyInserted
    case useOneShotInsertion
    case retainedInHistoryOnly
}

@MainActor
final class LiveTextInsertionSession {
    init(capturer: any LiveTextTargetCapturing = AXLiveTextTargetCapturer())
    func render(_ snapshot: String) async
    func finalize(_ finalText: String) async -> LiveTextFinalization
    func cancel() async
}
```

The internal state stores the original selection and text, the currently owned text, and whether a verified mutation has occurred. The target adapter performs one atomic operation:

```swift
@MainActor
protocol LiveTextTarget: AnyObject {
    func replace(
        expectedSelection: NSRange,
        ownedRange: NSRange,
        expectedText: String,
        replacement: String
    ) async -> LiveTextMutationResult
}
```

Before mutation, verify the same focused element, expected selection, selected owned range, and selected text. Try AX selected-text replacement first. Use the existing pasteboard strategy only after a verified owned range is selected. Verify the replacement and restore a collapsed caret at its end. Return an uncertain result if a mutation may have landed but cannot be verified.

- [ ] **Step 4: Run the focused tests and confirm GREEN**

Run: `make test TEST_FILTER=LiveTextInsertionSessionTests`

Expected: all owned-range state-machine tests pass.

- [ ] **Step 5: Commit the safety module**

```bash
git add Sources/MurmurYouTube/Core/LiveTextInsertionSession.swift Sources/MurmurYouTube/Core/TextInjector.swift Tests/MurmurYouTubeTests/LiveTextInsertionSessionTests.swift
git commit -m "feat: add verified live text ownership"
```

### Task 3: Route Apple snapshots through live insertion

**Files:**
- Modify: `Sources/MurmurYouTube/Core/DictationController.swift`
- Modify: `Tests/MurmurYouTubeTests/LiveTextInsertionSessionTests.swift`

**Interfaces:**
- Consumes: `Settings.textInsertionTiming`
- Consumes: `LiveTextInsertionSession.render`, `finalize`, and `cancel`
- Preserves: `RecordingSessionCoordinator.completeLiveSession`

- [ ] **Step 1: Write failing routing-policy tests**

Add pure policy expectations:

```swift
@Test(arguments: [
    LiveTypingScenario(timing: .whileSpeaking, engine: .apple, compare: false, expected: true),
    LiveTypingScenario(timing: .afterSpeaking, engine: .apple, compare: false, expected: false),
    LiveTypingScenario(timing: .whileSpeaking, engine: .parakeet, compare: false, expected: false),
    LiveTypingScenario(timing: .whileSpeaking, engine: .apple, compare: true, expected: false),
])
func liveTypingActivation(_ scenario: LiveTypingScenario) {
    #expect(LiveTypingPolicy.isEnabled(
        timing: scenario.timing,
        engine: scenario.engine,
        compareMode: scenario.compare
    ) == scenario.expected)
}
```

- [ ] **Step 2: Run the focused tests and confirm RED**

Run: `make test TEST_FILTER=LiveTextInsertionSessionTests`

Expected: compilation fails because `LiveTypingPolicy` does not exist.

- [ ] **Step 3: Integrate the per-utterance session**

Add `insertionTiming` to `LiveTranscriptionConfiguration`. Capture a live session at dictation start only when the pure policy returns true. In the chunk consumer, assign the HUD transcript and await `render(chunk.text)`. On release, run the existing cleanup, snippet, and dictionary pipeline first, then call `finalize(output)`.

Route final completion as follows:

```swift
let disposition = await liveInsertion?.finalize(output) ?? .useOneShotInsertion
let completed = await sessionCoordinator.completeLiveSession(
    sessionID: sessionID,
    run: run,
    insert: { text in
        if disposition == .useOneShotInsertion { TextInjector.insert(text) }
    }
)
```

For `.retainedInHistoryOnly`, finish durability without another insertion and show a localized recoverable message. Every cancellation, teardown, empty transcript, and failure path calls `cancel()` before discarding the session.

- [ ] **Step 4: Run focused and coordinator tests**

Run: `make test TEST_FILTER=LiveTextInsertionSessionTests`

Run: `make test TEST_FILTER=RecordingSessionCoordinatorTests`

Expected: both suites pass.

- [ ] **Step 5: Commit controller integration**

```bash
git add Sources/MurmurYouTube/Core/DictationController.swift Tests/MurmurYouTubeTests/LiveTextInsertionSessionTests.swift
git commit -m "feat: type Apple transcription while speaking"
```

### Task 4: Add localized Settings control without redesign

**Files:**
- Modify: `Sources/MurmurYouTube/UI/SettingsWindow.swift`
- Modify: `Sources/MurmurYouTube/Localization/catalog.tsv`
- Modify: `Tests/MurmurYouTubeTests/AppLocalizationTests.swift`

**Interfaces:**
- Consumes: `Settings.textInsertionTiming`
- Consumes: `LiveTypingPolicy.isEnabled`

- [ ] **Step 1: Add failing localization coverage**

Extend the required interface strings with:

```swift
"When should Murmure type?",
"After I finish speaking",
"While I’m speaking",
"Live typing is ready with Apple.",
"Live typing requires Apple and a selected spoken language. With these settings, Murmure will type after you finish.",
"Live typing stopped because the destination changed. Your final text is saved in History."
```

- [ ] **Step 2: Run localization tests and confirm RED**

Run: `make test TEST_FILTER=AppLocalizationTests`

Expected: the catalog coverage test reports missing French and Spanish values.

- [ ] **Step 3: Add the picker and translated copy**

Place the menu picker after the spoken-language status and before Compare Mode:

```swift
Picker(L10n.text("When should Murmure type?"), selection: $settings.textInsertionTiming) {
    Text(L10n.text("After I finish speaking")).tag(TextInsertionTiming.afterSpeaking)
    Text(L10n.text("While I’m speaking")).tag(TextInsertionTiming.whileSpeaking)
}
.pickerStyle(.menu)
.frame(maxWidth: 260, alignment: .leading)

Text(L10n.text(liveTypingStatusText))
    .font(DS.Font.caption)
    .foregroundStyle(liveTypingIsAvailable ? DS.Color.inkSecondary : DS.Color.warning)
    .fixedSize(horizontal: false, vertical: true)
```

Use natural French and Spanish translations in `catalog.tsv`. Do not change the existing card, navigation, spacing, typography, colors, or other categories.

- [ ] **Step 4: Run localization tests and confirm GREEN**

Run: `make test TEST_FILTER=AppLocalizationTests`

Expected: all localization tests pass.

- [ ] **Step 5: Commit the UI slice**

```bash
git add Sources/MurmurYouTube/UI/SettingsWindow.swift Sources/MurmurYouTube/Localization/catalog.tsv Tests/MurmurYouTubeTests/AppLocalizationTests.swift
git commit -m "feat: expose localized live typing option"
```

### Task 5: Full verification and installed-app proof

**Files:**
- Modify only if verification finds a defect in the files above.

**Interfaces:**
- Verifies the complete feature on source, bundle, and installed app surfaces.

- [ ] **Step 1: Run static and full automated checks**

Run: `git diff --check 8bfc87c..HEAD`

Run: `make test`

Run: `make`

Expected: no whitespace errors, all Swift tests pass, and the signed application bundle builds successfully.

- [ ] **Step 2: Install the application**

Run: `make install`

Expected: `/Applications/Murmure.app` is replaced by the newly signed build without creating duplicate application bundles.

- [ ] **Step 3: Verify the installed Settings surface**

Launch `/Applications/Murmure.app`. Open Settings > Dictation in English, French, and Spanish. Confirm the new picker and status line are present and every protected category retains its existing layout and visual language.

- [ ] **Step 4: Verify the original live-typing scenario**

Use Apple with an explicit spoken language and “While I’m speaking.” Hold FN and dictate into a real text field. Confirm partial text updates while speaking and the final owned range becomes the cleaned result after release.

Move the caret during a second dictation. Confirm Murmure stops live mutation, does not delete unrelated text, and retains the final transcript in History without duplicating it into the field.

- [ ] **Step 5: Verify protected behavior**

Switch to “After I finish speaking” and confirm nothing enters the destination before FN release. Confirm Automatic language and Parakeet also insert only after release. Confirm Compare Mode does not type.

- [ ] **Step 6: Record final evidence**

Record the installed bundle path, version, code-signing identity, relevant screenshots, test counts, and any exact-surface limitation. Do not claim complete if the real live dictation scenario was not exercised.
