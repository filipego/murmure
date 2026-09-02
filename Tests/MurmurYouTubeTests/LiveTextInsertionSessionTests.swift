import Foundation
import Testing
@testable import MurmurYouTube

@Suite("Verified live text ownership")
@MainActor
struct LiveTextInsertionSessionTests {
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
