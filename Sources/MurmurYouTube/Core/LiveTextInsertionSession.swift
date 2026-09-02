import AppKit
import ApplicationServices
import Foundation

enum LiveTextFinalization: Equatable, Sendable {
    case alreadyInserted
    case useOneShotInsertion
    case retainedInHistoryOnly
}

enum LiveTextMutationResult: Equatable, Sendable {
    case replaced
    case notMutated
    case uncertain
}

@MainActor
protocol LiveTextTarget: AnyObject {
    func replace(
        expectedSelection: NSRange,
        ownedRange: NSRange,
        expectedText: String,
        replacement: String
    ) async -> LiveTextMutationResult
}

struct LiveTextTargetCapture {
    let target: any LiveTextTarget
    let selection: NSRange
    let selectedText: String
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
        case abandoned(LiveTextFinalization)
        case finished
        case cancelled
    }

    private var state: State
    private var mutationInFlight = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(capturer: any LiveTextTargetCapturing = AXLiveTextTargetCapturer()) {
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
        await beginMutation()
        defer { endMutation() }

        guard !snapshot.isEmpty, case .active(let ownership) = state else { return }
        apply(
            await ownership.target.replace(
                expectedSelection: ownership.expectedSelection,
                ownedRange: ownership.ownedRange,
                expectedText: ownership.ownedText,
                replacement: snapshot
            ),
            replacement: snapshot,
            to: ownership
        )
    }

    func finalize(_ finalText: String) async -> LiveTextFinalization {
        await beginMutation()
        defer { endMutation() }

        switch state {
        case .unavailable:
            state = .finished
            return .useOneShotInsertion
        case .abandoned(let result):
            state = .finished
            return result
        case .finished, .cancelled:
            return .alreadyInserted
        case .active(let ownership):
            guard !finalText.isEmpty else {
                await cancel(ownership)
                return .alreadyInserted
            }

            let result = await ownership.target.replace(
                expectedSelection: ownership.expectedSelection,
                ownedRange: ownership.ownedRange,
                expectedText: ownership.ownedText,
                replacement: finalText
            )
            let finalization = finalization(after: result, ownership: ownership)
            state = .finished
            return finalization
        }
    }

    func cancel() async {
        await beginMutation()
        defer { endMutation() }

        guard case .active(let ownership) = state else {
            state = .cancelled
            return
        }

        await cancel(ownership)
    }

    private func cancel(_ ownership: Ownership) async {
        guard ownership.hasVerifiedMutation else {
            state = .cancelled
            return
        }

        _ = await ownership.target.replace(
            expectedSelection: ownership.expectedSelection,
            ownedRange: ownership.ownedRange,
            expectedText: ownership.ownedText,
            replacement: ownership.originalText
        )
        state = .cancelled
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
            guard let replacementRange = Self.range(
                startingAt: ownership.ownedRange.location,
                text: replacement
            ) else {
                state = .abandoned(.retainedInHistoryOnly)
                return
            }

            var updated = ownership
            updated.expectedSelection = NSRange(
                location: replacementRange.location + replacementRange.length,
                length: 0
            )
            updated.ownedRange = replacementRange
            updated.ownedText = replacement
            updated.hasVerifiedMutation = true
            state = .active(updated)
        case .notMutated:
            state = .abandoned(
                ownership.hasVerifiedMutation ? .retainedInHistoryOnly : .useOneShotInsertion
            )
        case .uncertain:
            state = .abandoned(.retainedInHistoryOnly)
        }
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

    private static func range(startingAt location: Int, text: String) -> NSRange? {
        guard location != NSNotFound, location >= 0 else { return nil }
        let (end, overflow) = location.addingReportingOverflow(text.utf16.count)
        guard !overflow else { return nil }
        return NSRange(location: location, length: end - location)
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
        guard let selectedText = target.text(in: selection) else { return nil }

        return LiveTextTargetCapture(
            target: target,
            selection: selection,
            selectedText: selectedText
        )
    }
}

@MainActor
private final class AXLiveTextTarget: LiveTextTarget {
    private enum ReplacementObservation {
        case verified
        case unchanged
        case uncertain
    }

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
        replacement: String
    ) async -> LiveTextMutationResult {
        guard isFocused,
              AXLiveTextSupport.selectedRange(of: element) == expectedSelection,
              text(in: ownedRange) == expectedText
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

        guard verifiedSelectedOwnedRange(ownedRange, expectedText: expectedText) else {
            return .uncertain
        }

        let didPaste = await TextInjector.pasteViaCommandV(replacement) { [weak self] in
            self?.verifiedSelectedOwnedRange(ownedRange, expectedText: expectedText) == true
        }
        guard didPaste else {
            restoreExpectedSelection(expectedSelection, ownedRange: ownedRange, expectedText: expectedText)
            return .notMutated
        }

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
        case .unchanged:
            restoreExpectedSelection(expectedSelection, ownedRange: ownedRange, expectedText: expectedText)
            return .notMutated
        case .uncertain:
            return .uncertain
        }
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
        isFocused
            && AXLiveTextSupport.selectedRange(of: element) == range
            && AXLiveTextSupport.selectedText(of: element) == expectedText
            && text(in: range) == expectedText
    }

    private func observeReplacement(
        ownedRange: NSRange,
        expectedText: String,
        replacement: String,
        documentBefore: String?
    ) -> ReplacementObservation {
        guard isFocused,
              let replacementRange = AXLiveTextSupport.range(
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
        guard let replacementRange = AXLiveTextSupport.range(
            startingAt: ownedRange.location,
            text: replacement
        ),
        isFocused,
        text(in: replacementRange) == replacement
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

    static func range(startingAt location: Int, text: String) -> NSRange? {
        guard location != NSNotFound, location >= 0 else { return nil }
        let (end, overflow) = location.addingReportingOverflow(text.utf16.count)
        guard !overflow else { return nil }
        return NSRange(location: location, length: end - location)
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
