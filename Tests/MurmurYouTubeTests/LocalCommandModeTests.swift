import Testing
@testable import MurmurYouTube

@Suite("Local selected-text Command Mode")
struct LocalCommandModeTests {
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
}
