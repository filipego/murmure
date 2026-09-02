import Foundation
import MurmurSessionCore
import Testing
@testable import MurmurYouTube

struct LiveTypingScenario: Sendable {
    let timing: TextInsertionTiming
    let engine: SpeechEngineChoice
    let compare: Bool
    let expected: Bool
}

@Suite("Verified live text ownership")
@MainActor
struct LiveTextInsertionSessionTests {
    @Test("invalidated operation tokens cannot act and replacements are distinct")
    func operationTokenLifecycle() {
        var lifecycle = DictationOperationLifecycle()
        let original = lifecycle.begin()

        lifecycle.invalidate()
        #expect(!lifecycle.isCurrent(original))

        let replacement = lifecycle.begin()
        #expect(replacement != original)
        #expect(lifecycle.isCurrent(replacement))
        #expect(!lifecycle.isCurrent(original))
    }

    @Test(
        "rollback blocks every recording-like start while visible idle",
        arguments: DictationStartEntryPoint.allCases
    )
    func idleStartPolicyHonorsCancellationLifecycle(_ entryPoint: DictationStartEntryPoint) {
        var lifecycle = DictationOperationLifecycle()
        _ = lifecycle.begin()

        let cancellation = lifecycle.beginCancellation()
        let visibleState = DictationController.State.idle
        #expect(visibleState == .idle)
        #expect(!DictationStartPolicy.canBegin(
            entryPoint: entryPoint,
            visibleState: visibleState,
            lifecycleCanBegin: lifecycle.canBegin
        ))
        #expect(lifecycle.isCancelling(cancellation))

        lifecycle.invalidate()
        #expect(!DictationStartPolicy.canBegin(
            entryPoint: entryPoint,
            visibleState: visibleState,
            lifecycleCanBegin: lifecycle.canBegin
        ))

        let completed = lifecycle.completeCancellation(cancellation)
        #expect(completed)
        #expect(DictationStartPolicy.canBegin(
            entryPoint: entryPoint,
            visibleState: visibleState,
            lifecycleCanBegin: lifecycle.canBegin
        ))
    }

    @Test("rollback rejects inactive hands-free start without mutating active state")
    func handsFreeStartGatePreservesInactivePolicy() {
        var rejectedPolicy = HandsFreeGesturePolicy()

        #expect(HandsFreeEventRoutingPolicy.handle(
            .bindingPressed,
            policy: &rejectedPolicy,
            canBegin: false
        ) == .ignore)
        #expect(!rejectedPolicy.isActive)

        var finishingPolicy = HandsFreeGesturePolicy()
        #expect(HandsFreeEventRoutingPolicy.handle(
            .bindingPressed,
            policy: &finishingPolicy,
            canBegin: true
        ) == .start)
        #expect(HandsFreeEventRoutingPolicy.handle(
            .enterPressed,
            policy: &finishingPolicy,
            canBegin: false
        ) == .finish)

        var cancellingPolicy = HandsFreeGesturePolicy()
        #expect(HandsFreeEventRoutingPolicy.handle(
            .bindingPressed,
            policy: &cancellingPolicy,
            canBegin: true
        ) == .start)
        #expect(HandsFreeEventRoutingPolicy.handle(
            .escapePressed,
            policy: &cancellingPolicy,
            canBegin: false
        ) == .cancel)
        #expect(!cancellingPolicy.isActive)
    }

    @Test("one-shot routing rejects an invalidated operation")
    func oneShotRoutingRequiresCurrentOperation() {
        #expect(!LiveTypingCompletionPolicy.shouldUseOneShotInsertion(
            disposition: .useOneShotInsertion,
            operationIsCurrent: false
        ))
        #expect(LiveTypingCompletionPolicy.shouldUseOneShotInsertion(
            disposition: .useOneShotInsertion,
            operationIsCurrent: true
        ))
    }

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

    @Test("successive snapshots replace only the owned range")
    func replacesOwnedRange() async {
        let target = FakeLiveTextTarget(
            selection: NSRange(location: 4, length: 0),
            text: "Say  now."
        )
        let session = LiveTextInsertionSession(capturer: target)

        await session.render("hel")
        #expect(target.documentText == "Say hel now.")
        await session.render("hello")

        #expect(target.replacements.map(\.replacement) == ["hel", "hello"])
        #expect(target.documentText == "Say hello now.")
    }

    @Test("caret movement stops mutation and prevents duplicate final insertion")
    func caretMovementAbandonsOwnedText() async {
        let target = FakeLiveTextTarget(selection: NSRange(location: 0, length: 0), text: "")
        let session = LiveTextInsertionSession(capturer: target)
        await session.render("hel")

        target.selection = NSRange(location: 1, length: 0)
        let result = await session.finalize("Hello.")

        #expect(result == .retainedInHistoryOnly)
        #expect(target.documentText == "hel")
        #expect(target.replacements.map(\.replacement) == ["hel"])
    }

    @Test("unavailable target before first mutation uses one shot final insertion")
    func unavailableTargetFallsBackCleanly() async {
        let target = FakeLiveTextTarget(selection: NSRange(location: 0, length: 0), text: "")
        target.isAvailable = false
        let session = LiveTextInsertionSession(capturer: target)

        #expect(await session.finalize("Hello.") == .useOneShotInsertion)
        #expect(target.documentText.isEmpty)
        #expect(target.replacements.isEmpty)
    }

    @Test("cancel restores the original selection only while ownership is verified")
    func verifiedCancelRollsBack() async {
        let originalText = "Keep selected words."
        let originalSelection = NSRange(location: 5, length: 8)
        let target = FakeLiveTextTarget(selection: originalSelection, text: originalText)
        let session = LiveTextInsertionSession(capturer: target)

        await session.render("temporary")
        await session.cancel()

        #expect(target.documentText == originalText)
        #expect(target.replacements.map(\.replacement) == ["temporary", "selected"])
    }

    @Test("finalization replaces verified live text exactly once")
    func finalizationIsIdempotent() async {
        let target = FakeLiveTextTarget(selection: NSRange(location: 0, length: 0), text: "")
        let session = LiveTextInsertionSession(capturer: target)
        await session.render("hello")

        #expect(await session.finalize("Hello.") == .alreadyInserted)
        #expect(await session.finalize("Hello.") == .alreadyInserted)
        #expect(target.documentText == "Hello.")
        #expect(target.replacements.map(\.replacement) == ["hello", "Hello."])
    }

    @Test("cancel never replaces text after the owned range changes")
    func unverifiedCancelPreservesExternalText() async {
        let target = FakeLiveTextTarget(selection: NSRange(location: 0, length: 0), text: "")
        let session = LiveTextInsertionSession(capturer: target)
        await session.render("temporary")

        target.replaceExternally(with: "user text")
        await session.cancel()

        #expect(target.documentText == "user text")
        #expect(target.replacements.map(\.replacement) == ["temporary"])
    }

    @Test("an uncertain first mutation never permits duplicate one shot insertion")
    func uncertainMutationIsRetainedInHistoryOnly() async {
        let target = FakeLiveTextTarget(selection: NSRange(location: 0, length: 0), text: "")
        target.nextOutcome = .uncertainAfterMutation
        let session = LiveTextInsertionSession(capturer: target)

        await session.render("maybe landed")

        #expect(await session.finalize("Final text") == .retainedInHistoryOnly)
        #expect(target.documentText == "maybe landed")
        #expect(target.replacements.map(\.replacement) == ["maybe landed"])
    }

    @Test("a posted paste with an unchanged observation remains uncertain")
    func postedPasteUnchangedNeverFallsBackCleanly() async {
        let target = FakeLiveTextTarget(selection: NSRange(location: 0, length: 0), text: "")
        target.nextOutcome = .postedPasteUnchanged
        let session = LiveTextInsertionSession(capturer: target)

        await session.render("possibly delayed")

        #expect(await session.finalize("Final text") == .retainedInHistoryOnly)
        #expect(target.documentText.isEmpty)
        #expect(target.replacements.map(\.replacement) == ["possibly delayed"])
    }

    @Test("an older suspended snapshot never overwrites newer text")
    func serializesSuspendedMutations() async {
        let target = FakeLiveTextTarget(selection: NSRange(location: 0, length: 0), text: "")
        let gate = FakeMutationGate()
        target.nextGate = gate
        let session = LiveTextInsertionSession(capturer: target)

        let older = Task { @MainActor in
            await session.render("old")
        }
        while !gate.isWaiting {
            await Task.yield()
        }

        let newer = Task { @MainActor in
            await session.render("new")
        }
        await Task.yield()
        gate.release()
        await older.value
        await newer.value

        #expect(await session.finalize("Final") == .alreadyInserted)
        #expect(target.documentText == "Final")
        #expect(target.replacements.map(\.replacement) == ["old", "new", "Final"])
    }

    @Test("cancel waits for suspended finalization and rolls it back")
    func cancelOverlappingFinalizationRollsBack() async {
        let originalText = "Keep selected words."
        let originalSelection = NSRange(location: 5, length: 8)
        let target = FakeLiveTextTarget(selection: originalSelection, text: originalText)
        let session = LiveTextInsertionSession(capturer: target)
        await session.render("draft")

        let gate = FakeMutationGate()
        target.nextGate = gate
        let finalization = Task { @MainActor in
            await session.finalize("Final")
        }
        while !gate.isWaiting {
            await Task.yield()
        }

        var cancellationCompleted = false
        let cancellation = Task { @MainActor in
            await session.cancel()
            cancellationCompleted = true
        }
        while session.pendingMutationCount == 0 {
            await Task.yield()
        }
        #expect(session.pendingMutationCount == 1)
        #expect(!cancellationCompleted)
        #expect(target.documentText == "Keep draft words.")
        gate.release()

        #expect(await finalization.value == .alreadyInserted)
        await cancellation.value

        #expect(target.documentText == originalText)
        #expect(target.replacements.map(\.replacement) == ["draft", "Final", "selected"])
        #expect(await session.finalize("Final") == .alreadyInserted)
    }

    @Test("committed final text is no longer cancellable")
    func commitEndsRollbackOwnership() async {
        let originalText = "Keep selected words."
        let originalSelection = NSRange(location: 5, length: 8)
        let target = FakeLiveTextTarget(selection: originalSelection, text: originalText)
        let session = LiveTextInsertionSession(capturer: target)
        await session.render("draft")

        #expect(await session.finalize("Final") == .alreadyInserted)
        await session.commit()
        await session.cancel()

        #expect(target.documentText == "Keep Final words.")
        #expect(target.replacements.map(\.replacement) == ["draft", "Final"])
    }
}

@MainActor
private final class FakeLiveTextTarget: LiveTextTargetCapturing, LiveTextTarget {
    struct Replacement: Equatable {
        let expectedSelection: NSRange
        let ownedRange: NSRange
        let expectedText: String
        let replacement: String
    }

    enum NextOutcome {
        case normal
        case postedPasteUnchanged
        case uncertainAfterMutation
    }

    var documentText: String
    var selection: NSRange
    var isAvailable = true
    var nextOutcome = NextOutcome.normal
    var nextGate: FakeMutationGate?
    private(set) var replacements: [Replacement] = []

    init(selection: NSRange, text: String) {
        self.selection = selection
        documentText = text
    }

    func capture() -> LiveTextTargetCapture? {
        guard isAvailable,
              let selectedText = documentText.substring(in: selection)
        else { return nil }

        return LiveTextTargetCapture(
            target: self,
            selection: selection,
            selectedText: selectedText
        )
    }

    func replace(
        expectedSelection: NSRange,
        ownedRange: NSRange,
        expectedText: String,
        replacement: String
    ) async -> LiveTextMutationResult {
        if let gate = nextGate {
            nextGate = nil
            await gate.wait()
        }

        guard isAvailable,
              selection == expectedSelection,
              documentText.substring(in: ownedRange) == expectedText
        else { return .notMutated }

        let requestedReplacement = Replacement(
            expectedSelection: expectedSelection,
            ownedRange: ownedRange,
            expectedText: expectedText,
            replacement: replacement
        )
        if nextOutcome == .postedPasteUnchanged {
            nextOutcome = .normal
            replacements.append(requestedReplacement)
            return .afterPostedPaste(.unchanged)
        }

        documentText = documentText.replacingCharacters(in: ownedRange, with: replacement)
        selection = NSRange(
            location: ownedRange.location + replacement.utf16.count,
            length: 0
        )
        replacements.append(requestedReplacement)

        if nextOutcome == .uncertainAfterMutation {
            nextOutcome = .normal
            return .uncertain
        }
        return .replaced
    }

    func replaceExternally(with text: String) {
        documentText = text
        selection = NSRange(location: text.utf16.count, length: 0)
    }
}

@MainActor
private final class FakeMutationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private extension String {
    func substring(in range: NSRange) -> String? {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              range.location <= utf16.count,
              range.length <= utf16.count - range.location,
              let swiftRange = Range(range, in: self)
        else { return nil }

        return String(self[swiftRange])
    }

    func replacingCharacters(in range: NSRange, with replacement: String) -> String {
        guard let swiftRange = Range(range, in: self) else { return self }
        var copy = self
        copy.replaceSubrange(swiftRange, with: replacement)
        return copy
    }
}
