import AppKit
import ApplicationServices
import Foundation

enum LiveTextFinalization: Equatable, Sendable {
    case alreadyInserted
    case useOneShotInsertion
    case retainedInHistoryOnly
}

enum LiveTextCancellation: Equatable, Sendable {
    case restored
    case noLiveText
    case retainedInHistoryOnly
}

enum LiveTextMutationResult: Equatable, Sendable {
    case replaced
    case notMutated
    case uncertain

    static func afterPostedPaste(
        _ observation: LiveTextReplacementObservation,
        verifiedOwnedRange: Bool = false
    ) -> LiveTextMutationResult {
        if verifiedOwnedRange { return .replaced }
        return switch observation {
        case .verified:
            .replaced
        case .unchanged, .uncertain:
            .uncertain
        }
    }
}

enum LiveTextReplacementObservation: Equatable, Sendable {
    case verified
    case unchanged
    case uncertain
}

private func liveTextRange(startingAt location: Int, text: String) -> NSRange? {
    guard location != NSNotFound, location >= 0 else { return nil }
    let (end, overflow) = location.addingReportingOverflow(text.utf16.count)
    guard !overflow else { return nil }
    return NSRange(location: location, length: end - location)
}

@MainActor
protocol LiveTextTarget: AnyObject {
    func replace(
        expectedSelection: NSRange,
        ownedRange: NSRange,
        expectedText: String,
        replacement: String,
        allowsPasteFallback: Bool,
        operationIsCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async -> LiveTextMutationResult
}

struct LiveTextTargetCapture {
    let target: any LiveTextTarget
    let selection: NSRange
    let selectedText: String
}

enum LiveTextCapturePolicy {
    static func selectedText(selection: NSRange, rangeText: String?) -> String? {
        selection.length == 0 ? "" : rangeText
    }
}

enum LiveTextOwnershipVerification {
    static func isVerified(
        expectedRange: NSRange,
        actualRange: NSRange?,
        expectedText: String,
        selectedText: String?,
        rangeText: String?
    ) -> Bool {
        guard actualRange == expectedRange,
              selectedText == expectedText
        else { return false }
        return rangeText.map { $0 == expectedText } ?? true
    }
}

@MainActor
protocol LiveTextTargetCapturing {
    func capture() -> LiveTextTargetCapture?
}

@MainActor
final class LiveTextInsertionSession {
    private struct Ownership {
        let target: any LiveTextTarget
        let originalSelection: NSRange
        let originalText: String
        var expectedSelection: NSRange
        var ownedRange: NSRange
        var ownedText: String
        var hasVerifiedMutation: Bool
    }

    private enum State {
        case unavailable
        case active(Ownership)
        case abandoned(Ownership, LiveTextFinalization)
        case finalized(Ownership?, LiveTextFinalization)
        case committed
        case cancelled
    }

    private var state: State
    private var mutationInFlight = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingSnapshot: String?
    private var renderTask: Task<Void, Never>?
    private var acceptsSnapshots = true
    private var discardsPendingSnapshots = false
    private let operationIsCurrent: @MainActor @Sendable () -> Bool

    /// Internal diagnostic count for mutations waiting behind the active target change.
    /// It provides lifecycle coordination without changing mutation scheduling.
    var pendingMutationCount: Int {
        mutationWaiters.count + (renderTask == nil ? 0 : 1)
    }

    init(
        capturer: any LiveTextTargetCapturing = AXLiveTextTargetCapturer(),
        operationIsCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
    ) {
        self.operationIsCurrent = operationIsCurrent
        guard let capture = capturer.capture() else {
            state = .unavailable
            return
        }

        state = .active(Ownership(
            target: capture.target,
            originalSelection: capture.selection,
            originalText: capture.selectedText,
            expectedSelection: capture.selection,
            ownedRange: capture.selection,
            ownedText: capture.selectedText,
            hasVerifiedMutation: false
        ))
    }

    func render(_ snapshot: String) async {
        schedule(snapshot)
        await renderTask?.value
    }

    /// Accepts high-frequency recognizer snapshots without making the producer wait for the
    /// accessibility target. Only the most recent pending snapshot is rendered.
    func schedule(_ snapshot: String) {
        guard acceptsSnapshots,
              operationIsCurrent(),
              !snapshot.isEmpty,
              case .active = state
        else { return }

        pendingSnapshot = snapshot
        guard renderTask == nil else { return }
        renderTask = Task { @MainActor [weak self] in
            // Let adjacent recognizer updates coalesce before the first target mutation.
            await Task.yield()
            await self?.drainPendingSnapshots()
        }
    }

    private func drainPendingSnapshots() async {
        defer { renderTask = nil }

        while !discardsPendingSnapshots, let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            await beginMutation()
            guard operationIsCurrent(), case .active(let ownership) = state else {
                endMutation()
                return
            }
            apply(
                await ownership.target.replace(
                    expectedSelection: ownership.expectedSelection,
                    ownedRange: ownership.ownedRange,
                    expectedText: ownership.ownedText,
                    replacement: snapshot,
                    allowsPasteFallback: true,
                    operationIsCurrent: operationIsCurrent
                ),
                replacement: snapshot,
                to: ownership
            )
            endMutation()
        }
    }

    private func waitForScheduledRenders(discardPending: Bool) async {
        acceptsSnapshots = false
        if discardPending {
            discardsPendingSnapshots = true
            pendingSnapshot = nil
        }
        await renderTask?.value
    }

    func finalize(_ finalText: String) async -> LiveTextFinalization {
        await waitForScheduledRenders(discardPending: false)
        await beginMutation()
        defer { endMutation() }

        switch state {
        case .unavailable:
            state = .finalized(nil, .useOneShotInsertion)
            return .useOneShotInsertion
        case .abandoned(let ownership, let result):
            guard !finalText.isEmpty else {
                let cancellation = await rollback(ownership)
                state = .cancelled
                return cancellation == .retainedInHistoryOnly
                    ? .retainedInHistoryOnly
                    : .alreadyInserted
            }
            guard ownership.hasVerifiedMutation else {
                state = .finalized(ownership, result)
                return result
            }
            let cancellation = await rollback(ownership)
            switch cancellation {
            case .restored:
                state = .finalized(nil, .useOneShotInsertion)
                return .useOneShotInsertion
            case .noLiveText:
                state = .finalized(ownership, result)
                return result
            case .retainedInHistoryOnly:
                state = .finalized(ownership, .retainedInHistoryOnly)
                return .retainedInHistoryOnly
            }
        case .finalized, .committed, .cancelled:
            return .alreadyInserted
        case .active(let ownership):
            guard !finalText.isEmpty else {
                let cancellation = await rollback(ownership)
                state = .cancelled
                return cancellation == .retainedInHistoryOnly
                    ? .retainedInHistoryOnly
                    : .alreadyInserted
            }

            let result = await ownership.target.replace(
                expectedSelection: ownership.expectedSelection,
                ownedRange: ownership.ownedRange,
                expectedText: ownership.ownedText,
                replacement: finalText,
                allowsPasteFallback: true,
                operationIsCurrent: operationIsCurrent
            )
            let finalization = finalization(after: result, ownership: ownership)
            let finalizedOwnership = result == .replaced
                ? updatedOwnership(replacingWith: finalText, from: ownership) ?? ownership
                : ownership
            state = .finalized(finalizedOwnership, finalization)
            return finalization
        }
    }

    func commit() async {
        await beginMutation()
        defer { endMutation() }

        guard case .finalized = state else { return }
        state = .committed
    }

    func cancel() async -> LiveTextCancellation {
        await waitForScheduledRenders(discardPending: true)
        await beginMutation()
        defer { endMutation() }

        let ownership: Ownership?
        let abandonedDisposition: LiveTextFinalization?
        switch state {
        case .active(let activeOwnership),
             .finalized(let activeOwnership?, _):
            ownership = activeOwnership
            abandonedDisposition = nil
        case .abandoned(let activeOwnership, let disposition):
            ownership = activeOwnership
            abandonedDisposition = disposition
        case .unavailable, .finalized(nil, _):
            state = .cancelled
            return .noLiveText
        case .committed, .cancelled:
            return .noLiveText
        }

        if let ownership {
            let cancellation: LiveTextCancellation
            if abandonedDisposition == .retainedInHistoryOnly,
               !ownership.hasVerifiedMutation {
                cancellation = .retainedInHistoryOnly
            } else {
                cancellation = await rollback(ownership)
            }
            state = .cancelled
            return cancellation
        }
        return .noLiveText
    }

    private func rollback(_ ownership: Ownership) async -> LiveTextCancellation {
        guard ownership.hasVerifiedMutation else {
            return .noLiveText
        }

        let result = await ownership.target.replace(
            expectedSelection: ownership.expectedSelection,
            ownedRange: ownership.ownedRange,
            expectedText: ownership.ownedText,
            replacement: ownership.originalText,
            allowsPasteFallback: false,
            operationIsCurrent: { true }
        )
        return result == .replaced ? .restored : .retainedInHistoryOnly
    }

    private func beginMutation() async {
        guard mutationInFlight else {
            mutationInFlight = true
            return
        }

        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func endMutation() {
        guard !mutationWaiters.isEmpty else {
            mutationInFlight = false
            return
        }

        let next = mutationWaiters.removeFirst()
        next.resume()
    }

    private func apply(
        _ result: LiveTextMutationResult,
        replacement: String,
        to ownership: Ownership
    ) {
        switch result {
        case .replaced:
            guard let updated = updatedOwnership(replacingWith: replacement, from: ownership) else {
                state = .abandoned(ownership, .retainedInHistoryOnly)
                return
            }
            state = .active(updated)
        case .notMutated:
            state = .abandoned(
                ownership,
                ownership.hasVerifiedMutation ? .retainedInHistoryOnly : .useOneShotInsertion
            )
        case .uncertain:
            state = .abandoned(ownership, .retainedInHistoryOnly)
        }
    }

    private func updatedOwnership(
        replacingWith replacement: String,
        from ownership: Ownership
    ) -> Ownership? {
        guard let replacementRange = liveTextRange(
            startingAt: ownership.ownedRange.location,
            text: replacement
        ) else { return nil }

        var updated = ownership
        updated.expectedSelection = NSRange(
            location: replacementRange.location + replacementRange.length,
            length: 0
        )
        updated.ownedRange = replacementRange
        updated.ownedText = replacement
        updated.hasVerifiedMutation = true
        return updated
    }

    private func finalization(
        after result: LiveTextMutationResult,
        ownership: Ownership
    ) -> LiveTextFinalization {
        switch result {
        case .replaced:
            return .alreadyInserted
        case .notMutated:
            return ownership.hasVerifiedMutation ? .retainedInHistoryOnly : .useOneShotInsertion
        case .uncertain:
            return .retainedInHistoryOnly
        }
    }
}

@MainActor
final class AXLiveTextTargetCapturer: LiveTextTargetCapturing {
    func capture() -> LiveTextTargetCapture? {
        guard let focused = AXLiveTextSupport.focusedElement(),
              let selection = AXLiveTextSupport.selectedRange(of: focused.element)
        else { return nil }

        let target = AXLiveTextTarget(
            element: focused.element,
            processIdentifier: focused.processIdentifier
        )
        guard let selectedText = LiveTextCapturePolicy.selectedText(
            selection: selection,
            rangeText: target.text(in: selection)
        ) else { return nil }

        return LiveTextTargetCapture(
            target: target,
            selection: selection,
            selectedText: selectedText
        )
    }
}

@MainActor
private final class AXLiveTextTarget: LiveTextTarget {
    private let element: AXUIElement
    private let processIdentifier: pid_t

    init(element: AXUIElement, processIdentifier: pid_t) {
        self.element = element
        self.processIdentifier = processIdentifier
    }

    func replace(
        expectedSelection: NSRange,
        ownedRange: NSRange,
        expectedText: String,
        replacement: String,
        allowsPasteFallback: Bool,
        operationIsCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async -> LiveTextMutationResult {
        guard operationIsCurrent(),
              isFocused,
              AXLiveTextSupport.selectedRange(of: element) == expectedSelection
        else { return .notMutated }

        let documentBefore = AXLiveTextSupport.documentText(of: element)
        guard AXLiveTextSupport.setSelectedRange(ownedRange, on: element),
              verifiedSelectedOwnedRange(ownedRange, expectedText: expectedText)
        else {
            restoreExpectedSelection(expectedSelection, ownedRange: ownedRange, expectedText: expectedText)
            return .notMutated
        }

        let writeResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        )

        switch observeReplacement(
            ownedRange: ownedRange,
            expectedText: expectedText,
            replacement: replacement,
            documentBefore: documentBefore
        ) {
        case .verified:
            return verifyAndCollapseCaret(ownedRange: ownedRange, replacement: replacement)
                ? .replaced
                : .uncertain
        case .uncertain:
            return .uncertain
        case .unchanged:
            guard writeResult != .success || replacement != expectedText else {
                return .uncertain
            }
        }

        guard allowsPasteFallback else { return .notMutated }

        guard verifiedSelectedOwnedRange(ownedRange, expectedText: expectedText) else {
            return .uncertain
        }

        let didPaste = await TextInjector.pasteViaCommandV(replacement) { [weak self] in
            operationIsCurrent()
                && self?.verifiedSelectedOwnedRange(ownedRange, expectedText: expectedText) == true
        }
        guard didPaste else {
            restoreExpectedSelection(expectedSelection, ownedRange: ownedRange, expectedText: expectedText)
            return .notMutated
        }

        if verifyAndCollapseCaret(ownedRange: ownedRange, replacement: replacement) {
            return .afterPostedPaste(.uncertain, verifiedOwnedRange: true)
        }

        let observation = observeReplacement(
            ownedRange: ownedRange,
            expectedText: expectedText,
            replacement: replacement,
            documentBefore: documentBefore
        )
        guard observation == .verified else {
            // Once Command-V is posted, an unchanged read is not proof that no write will
            // arrive. The target app may consume the event after our observation window.
            return .afterPostedPaste(observation)
        }
        return verifyAndCollapseCaret(ownedRange: ownedRange, replacement: replacement)
            ? .afterPostedPaste(.verified)
            : .uncertain
    }

    fileprivate func text(in range: NSRange) -> String? {
        AXLiveTextSupport.text(in: range, of: element)
    }

    private var isFocused: Bool {
        guard let focused = AXLiveTextSupport.focusedElement() else { return false }
        return focused.processIdentifier == processIdentifier
            && CFEqual(focused.element, element)
    }

    private func verifiedSelectedOwnedRange(_ range: NSRange, expectedText: String) -> Bool {
        isFocused && LiveTextOwnershipVerification.isVerified(
            expectedRange: range,
            actualRange: AXLiveTextSupport.selectedRange(of: element),
            expectedText: expectedText,
            selectedText: AXLiveTextSupport.selectedText(of: element),
            rangeText: text(in: range)
        )
    }

    private func observeReplacement(
        ownedRange: NSRange,
        expectedText: String,
        replacement: String,
        documentBefore: String?
    ) -> LiveTextReplacementObservation {
        guard isFocused,
              let replacementRange = liveTextRange(
                startingAt: ownedRange.location,
                text: replacement
              )
        else { return .uncertain }

        if let documentBefore,
           let expectedDocument = AXLiveTextSupport.replacing(
            range: ownedRange,
            in: documentBefore,
            with: replacement
           ),
           let currentDocument = AXLiveTextSupport.documentText(of: element) {
            if currentDocument == expectedDocument { return .verified }
            if currentDocument == documentBefore { return .unchanged }
            return .uncertain
        }

        let currentSelection = AXLiveTextSupport.selectedRange(of: element)
        if LiveTextOwnershipVerification.isVerified(
            expectedRange: replacementRange,
            actualRange: currentSelection,
            expectedText: replacement,
            selectedText: AXLiveTextSupport.selectedText(of: element),
            rangeText: text(in: replacementRange)
        ) {
            return .verified
        }
        if text(in: ownedRange) == expectedText, currentSelection == ownedRange {
            return replacement == expectedText ? .verified : .unchanged
        }

        let collapsedCaret = NSRange(
            location: replacementRange.location + replacementRange.length,
            length: 0
        )
        let plausibleSelection = currentSelection == ownedRange
            || currentSelection == replacementRange
            || currentSelection == collapsedCaret
        guard plausibleSelection, text(in: replacementRange) == replacement else {
            return .uncertain
        }
        return .verified
    }

    private func verifyAndCollapseCaret(ownedRange: NSRange, replacement: String) -> Bool {
        guard let replacementRange = liveTextRange(
            startingAt: ownedRange.location,
            text: replacement
        ),
        isFocused
        else { return false }

        let currentSelection = AXLiveTextSupport.selectedRange(of: element)
        let collapsedCaret = NSRange(
            location: replacementRange.location + replacementRange.length,
            length: 0
        )
        guard currentSelection == ownedRange
                || currentSelection == replacementRange
                || currentSelection == collapsedCaret,
              AXLiveTextSupport.setSelectedRange(replacementRange, on: element),
              verifiedSelectedOwnedRange(replacementRange, expectedText: replacement),
              AXLiveTextSupport.setSelectedRange(collapsedCaret, on: element),
              isFocused,
              AXLiveTextSupport.selectedRange(of: element) == collapsedCaret
        else { return false }

        return true
    }

    private func restoreExpectedSelection(
        _ expectedSelection: NSRange,
        ownedRange: NSRange,
        expectedText: String
    ) {
        guard verifiedSelectedOwnedRange(ownedRange, expectedText: expectedText) else { return }
        _ = AXLiveTextSupport.setSelectedRange(expectedSelection, on: element)
    }
}

private enum AXLiveTextSupport {
    struct FocusedElement {
        let element: AXUIElement
        let processIdentifier: pid_t
    }

    @MainActor
    static func focusedElement() -> FocusedElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }

        let element = unsafeDowncast(value as AnyObject, to: AXUIElement.self)
        var processIdentifier = pid_t()
        guard AXUIElementGetPid(element, &processIdentifier) == .success else { return nil }
        return FocusedElement(element: element, processIdentifier: processIdentifier)
    }

    static func selectedRange(of element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        let axValue = unsafeDowncast(value as AnyObject, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0,
              range.length >= 0
        else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    static func selectedText(of element: AXUIElement) -> String? {
        stringAttribute(kAXSelectedTextAttribute as CFString, of: element)
    }

    static func documentText(of element: AXUIElement) -> String? {
        stringAttribute(kAXValueAttribute as CFString, of: element)
    }

    static func text(in range: NSRange, of element: AXUIElement) -> String? {
        guard let axRange = axValue(for: range) else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &value
        ) == .success,
        let string = value as? String {
            return string
        }

        guard let document = documentText(of: element),
              let swiftRange = Range(range, in: document)
        else { return nil }
        return String(document[swiftRange])
    }

    static func setSelectedRange(_ range: NSRange, on element: AXUIElement) -> Bool {
        guard let value = axValue(for: range) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }

    static func replacing(range: NSRange, in text: String, with replacement: String) -> String? {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location
        else { return nil }
        return (text as NSString).replacingCharacters(in: range, with: replacement)
    }

    private static func stringAttribute(
        _ attribute: CFString,
        of element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func axValue(for range: NSRange) -> AXValue? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else {
            return nil
        }
        var cfRange = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &cfRange)
    }
}
