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

struct LiveTypingStatusScenario: Sendable {
    let timing: TextInsertionTiming
    let engine: SpeechEngineChoice
    let compare: Bool
    let expectedTextKey: String
}

@Suite("Verified live text ownership")
@MainActor
struct LiveTextInsertionSessionTests {
    @Test("keystroke fallback appends new speech without rewriting the stable prefix")
    func keystrokeFallbackAppendPlan() {
        #expect(LiveTextKeystrokePlan(from: "hello", to: "hello world") == .init(
            deleteCount: 0,
            insertion: " world"
        ))
    }

    @Test("keystroke fallback revises only the changed speech tail")
    func keystrokeFallbackRevisionPlan() {
        #expect(LiveTextKeystrokePlan(from: "I scream", to: "ice cream") == .init(
            deleteCount: 8,
            insertion: "ice cream"
        ))
    }

    @Test("keystroke fallback counts user-visible characters")
    func keystrokeFallbackGraphemePlan() {
        #expect(LiveTextKeystrokePlan(from: "go 👍🏽", to: "go now") == .init(
            deleteCount: 1,
            insertion: "now"
        ))
    }

    @Test("a collapsed caret can be captured without range text support")
    func collapsedCaretCapturePolicy() {
        #expect(LiveTextCapturePolicy.selectedText(
            selection: NSRange(location: 4, length: 0),
            rangeText: nil
        ) == "")
    }

    @Test("a non-empty selection still requires readable original text")
    func selectedTextCapturePolicy() {
        #expect(LiveTextCapturePolicy.selectedText(
            selection: NSRange(location: 4, length: 3),
            rangeText: nil
        ) == nil)
        #expect(LiveTextCapturePolicy.selectedText(
            selection: NSRange(location: 4, length: 3),
            rangeText: "abc"
        ) == "abc")
    }

    @Test("selected text verifies an owned range when range text is unsupported")
    func selectedTextFallbackVerification() {
        #expect(LiveTextOwnershipVerification.isVerified(
            expectedRange: NSRange(location: 2, length: 5),
            actualRange: NSRange(location: 2, length: 5),
            expectedText: "draft",
            selectedText: "draft",
            rangeText: nil
        ))
        #expect(!LiveTextOwnershipVerification.isVerified(
            expectedRange: NSRange(location: 2, length: 5),
            actualRange: NSRange(location: 2, length: 5),
            expectedText: "draft",
            selectedText: "changed",
            rangeText: nil
        ))
        #expect(!LiveTextOwnershipVerification.isVerified(
            expectedRange: NSRange(location: 2, length: 5),
            actualRange: NSRange(location: 3, length: 5),
            expectedText: "draft",
            selectedText: "draft",
            rangeText: nil
        ))
    }

    @Test("a posted paste becomes owned when selecting its inserted range verifies the text")
    func postedPasteCanBecomeVerifiedOwnership() {
        #expect(LiveTextMutationResult.afterPostedPaste(
            .uncertain,
            verifiedOwnedRange: true
        ) == .replaced)
        #expect(LiveTextMutationResult.afterPostedPaste(
            .unchanged,
            verifiedOwnedRange: false
        ) == .uncertain)
    }
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

    @Test("controller-to-coordinator delivery keeps final, failed, stale, compare, and protected paths distinct")
    func completionDeliveryBoundary() {
        #expect(LiveTypingCompletionPolicy.delivery(
            disposition: .useOneShotInsertion,
            operationIsCurrent: true,
            compareMode: false
        ) == .insertOneShot)
        #expect(LiveTypingCompletionPolicy.delivery(
            disposition: .alreadyInserted,
            operationIsCurrent: true,
            compareMode: false
        ) == .alreadyDelivered)
        #expect(LiveTypingCompletionPolicy.delivery(
            disposition: .retainedInHistoryOnly,
            operationIsCurrent: true,
            compareMode: false
        ) == .retainInHistory)
        #expect(LiveTypingCompletionPolicy.delivery(
            disposition: .useOneShotInsertion,
            operationIsCurrent: false,
            compareMode: false
        ) == .suppressed)
        #expect(LiveTypingCompletionPolicy.delivery(
            disposition: .useOneShotInsertion,
            operationIsCurrent: true,
            compareMode: true
        ) == .suppressed)
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

    @Test(arguments: [
        LiveTypingStatusScenario(
            timing: .afterSpeaking,
            engine: .apple,
            compare: false,
            expectedTextKey: "Murmure will type after you finish speaking."
        ),
        LiveTypingStatusScenario(
            timing: .whileSpeaking,
            engine: .apple,
            compare: false,
            expectedTextKey: "Live typing is ready with Apple."
        ),
        LiveTypingStatusScenario(
            timing: .whileSpeaking,
            engine: .parakeet,
            compare: false,
            expectedTextKey: "Live typing requires Apple and a selected spoken language. With these settings, Murmure will type after you finish."
        ),
        LiveTypingStatusScenario(
            timing: .whileSpeaking,
            engine: .apple,
            compare: true,
            expectedTextKey: "Compare Mode shows both engines, so Murmure will not type into the destination."
        ),
    ])
    func liveTypingStatus(_ scenario: LiveTypingStatusScenario) {
        #expect(LiveTypingStatusPolicy.textKey(
            timing: scenario.timing,
            engine: scenario.engine,
            compareMode: scenario.compare
        ) == scenario.expectedTextKey)
    }

    @Test("operation invalidation suppresses a pending live render")
    func staleOperationSuppressesPendingRender() async {
        let target = FakeLiveTextTarget(selection: NSRange(location: 0, length: 0), text: "")
        let validity = FakeOperationValidity()
        let session = LiveTextInsertionSession(
            capturer: target,
            operationIsCurrent: { validity.isCurrent }
        )

        session.schedule("draft")
        validity.isCurrent = false
        await Task.yield()

        #expect(target.documentText.isEmpty)
        #expect(target.replacements.isEmpty)
    }

    @Test("Command-V policy rejects cancellation before either post window and preserves foreign clipboard changes")
    func commandVPastePolicyIsCancellationAndOwnershipSafe() {
        #expect(!LiveTextPastePolicy.canPostCommandV(
            taskIsCancelled: true,
            operationIsCurrent: true
        ))
        #expect(!LiveTextPastePolicy.canPostCommandV(
            taskIsCancelled: false,
            operationIsCurrent: false
        ))
        #expect(LiveTextPastePolicy.canPostCommandV(
            taskIsCancelled: false,
            operationIsCurrent: true
        ))
        #expect(LiveTextPastePolicy.shouldRestorePasteboard(
            currentChangeCount: 3,
            ownedChangeCount: 3
        ))
        #expect(!LiveTextPastePolicy.shouldRestorePasteboard(
            currentChangeCount: 4,
            ownedChangeCount: 3
        ))
    }

    @Test("uncertain rollback keeps the staged recording recoverable")
    func uncertainRollbackRecoveryPolicy() {
        #expect(LiveTypingCancellationRecoveryPolicy.retainsRecoverableRecording(
            .retainedInHistoryOnly
        ))
        #expect(!LiveTypingCancellationRecoveryPolicy.retainsRecoverableRecording(.restored))
        #expect(!LiveTypingCancellationRecoveryPolicy.retainsRecoverableRecording(.noLiveText))
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
        _ = await session.cancel()

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
        _ = await session.cancel()

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

    @Test("cancelling an uncertain first mutation keeps the recording recoverable")
    func uncertainFirstMutationCancellationIsRecoverable() async {
        let target = FakeLiveTextTarget(selection: NSRange(location: 0, length: 0), text: "")
        target.nextOutcome = .uncertainAfterMutation
        let session = LiveTextInsertionSession(capturer: target)

        await session.render("maybe landed")

        #expect(await session.cancel() == .retainedInHistoryOnly)
        #expect(target.documentText == "maybe landed")
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

    @Test("cancelling an unobserved posted paste keeps the recording recoverable")
    func postedPasteCancellationIsRecoverable() async {
        let target = FakeLiveTextTarget(selection: NSRange(location: 0, length: 0), text: "")
        target.nextOutcome = .postedPasteUnchanged
        let session = LiveTextInsertionSession(capturer: target)

        await session.render("possibly delayed")

        #expect(await session.cancel() == .retainedInHistoryOnly)
        #expect(target.documentText.isEmpty)
    }

    @Test("rapid snapshots coalesce to the latest pending text before finalization")
    func coalescesRapidSnapshots() async {
        let target = FakeLiveTextTarget(selection: NSRange(location: 0, length: 0), text: "")
        let session = LiveTextInsertionSession(capturer: target)

        session.schedule("old")
        session.schedule("new")

        #expect(await session.finalize("Final") == .alreadyInserted)
        #expect(target.documentText == "Final")
        #expect(target.replacements.map(\.replacement) == ["new", "Final"])
    }

    @Test("restored exact ownership removes abandoned live text before one-shot fallback")
    func restoredOwnershipRollsBackBeforeFallback() async {
        let target = FakeLiveTextTarget(selection: NSRange(location: 0, length: 0), text: "")
        let session = LiveTextInsertionSession(capturer: target)
        await session.render("draft")

        target.selection = NSRange(location: 0, length: 0)
        await session.render("ignored")
        target.selection = NSRange(location: 5, length: 0)

        #expect(await session.finalize("Final") == .useOneShotInsertion)
        #expect(target.documentText.isEmpty)
        #expect(target.replacements.map(\.replacement) == ["draft", ""])
    }

    @Test("cancellation reports retained temporary text when exact rollback is no longer safe")
    func cancellationReportsRollbackUncertainty() async {
        let target = FakeLiveTextTarget(selection: NSRange(location: 0, length: 0), text: "")
        let session = LiveTextInsertionSession(capturer: target)
        await session.render("draft")

        target.selection = NSRange(location: 0, length: 0)

        #expect(await session.cancel() == .retainedInHistoryOnly)
        #expect(target.documentText == "draft")
    }

    @Test("empty finalization reports retained temporary text when rollback is uncertain")
    func emptyFinalizationReportsRollbackUncertainty() async {
        let target = FakeLiveTextTarget(selection: NSRange(location: 0, length: 0), text: "")
        let session = LiveTextInsertionSession(capturer: target)
        await session.render("draft")

        target.selection = NSRange(location: 0, length: 0)

        #expect(await session.finalize("") == .retainedInHistoryOnly)
        #expect(target.documentText == "draft")
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
            _ = await session.cancel()
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
        _ = await session.cancel()

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
        replacement: String,
        allowsPasteFallback: Bool,
        operationIsCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async -> LiveTextMutationResult {
        if let gate = nextGate {
            nextGate = nil
            await gate.wait()
        }

        guard operationIsCurrent(),
              isAvailable,
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
private final class FakeOperationValidity {
    var isCurrent = true
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
