import Testing
@testable import MurmurYouTube

@Suite("Local selected-text Command Mode")
struct LocalCommandModeTests {
    @Test("model availability is queried only once per settings lifetime")
    @MainActor
    func availabilityLoadsOnce() {
        let availability = LocalCommandAvailabilityStore()
        var queryCount = 0

        availability.loadIfNeeded {
            queryCount += 1
            return nil
        }
        availability.loadIfNeeded {
            queryCount += 1
            return "unexpected second query"
        }

        #expect(queryCount == 1)
        #expect(availability.state == .available)
    }

    @Test("the request contains only the selected text, instruction, and source app")
    func requestContract() {
        let request = LocalCommandRequest(
            selectedText: "Original paragraph",
            instruction: "Make this more concise",
            sourceApplicationName: "TextEdit"
        )

        #expect(request == LocalCommandRequest(
            selectedText: "Original paragraph",
            instruction: "Make this more concise",
            sourceApplicationName: "TextEdit"
        ))
    }

    @Test("only idle and failed states may begin another command")
    func startPolicy() {
        #expect(LocalCommandPolicy.canBegin(from: .idle))
        #expect(LocalCommandPolicy.canBegin(from: .failed("Try again")))
        #expect(!LocalCommandPolicy.canBegin(from: .recordingInstruction))
        #expect(!LocalCommandPolicy.canBegin(from: .processing))
        #expect(!LocalCommandPolicy.canBegin(from: .review(original: "a", proposed: "b")))
    }

    @Test("replacement requires the exact captured selection to remain selected")
    func guardedReplacement() {
        #expect(LocalCommandPolicy.replacementDecision(
            capturedOriginal: "Exact selection",
            currentSelection: "Exact selection"
        ) == .replace)
        #expect(LocalCommandPolicy.replacementDecision(
            capturedOriginal: "Exact selection",
            currentSelection: "Changed selection"
        ) == .refuseSelectionChanged)
        #expect(LocalCommandPolicy.replacementDecision(
            capturedOriginal: "Exact selection",
            currentSelection: nil
        ) == .refuseSelectionUnavailable)
    }

    @Test("blank and runaway proposals are refused without rewriting them")
    func proposalValidation() {
        #expect(LocalCommandPolicy.validatedProposal("  \n") == nil)
        #expect(LocalCommandPolicy.validatedProposal(" keep my spacing ") == " keep my spacing ")
        #expect(LocalCommandPolicy.validatedProposal(
            String(repeating: "x", count: LocalCommandPolicy.maximumProposalCharacters + 1)
        ) == nil)
    }

    @Test("a refused replacement keeps the editable proposal available for copying")
    func refusedReplacementReview() {
        let state = LocalCommandPolicy.reviewState(
            after: .refusedSelectionChanged,
            original: "Original",
            proposed: "Proposal"
        )

        #expect(state == .review(
            original: "Original",
            proposed: "Proposal",
            notice: "The original selection changed, so Murmure refused to replace it. Copy the proposal instead."
        ))
    }
}
