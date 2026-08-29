import Foundation
import Testing

@testable import MurmurDictionary

struct CorrectionLearnerTests {
    @Test("learns the smallest contextual rule for a lie to a line")
    func simpleContextRule() {
        let plan = CorrectionLearner.plan(heard: "Everything is a lie.", intended: "Everything is a line.")
        #expect(plan.suggestion?.hear == "a lie")
        #expect(plan.suggestion?.write == "a line")
    }

    @Test("adds neighboring context when a single word is ambiguous")
    func bananaContextRule() {
        let plan = CorrectionLearner.plan(
            heard: "I spoke to banana yesterday.",
            intended: "I spoke to Mariana yesterday."
        )
        #expect(plan.suggestion?.hear == "to banana")
        #expect(plan.suggestion?.write == "to Mariana")
    }

    @Test("expands repeated-token edits so the untouched occurrence remains unchanged")
    func repeatedTokenExpansion() {
        let plan = CorrectionLearner.plan(heard: "lie and lie", intended: "line and lie")
        #expect(plan.suggestion?.hear == "lie and")
        #expect(plan.suggestion?.write == "line and")
        let applied = DictionaryCorrector(entries: [
            .correction(hear: plan.suggestion!.hear, write: plan.suggestion!.write)
        ]).apply(to: "lie and lie").text
        #expect(applied == "line and lie")
    }

    @Test("keeps straight and curly apostrophes inside one Unicode word")
    func contractionsRemainWholeWords() {
        let plan = CorrectionLearner.plan(heard: "we don't agree", intended: "we can agree")
        #expect(plan.suggestion?.hear == "we don't")
        #expect(plan.suggestion?.write == "we can")

        let curly = CorrectionLearner.plan(heard: "we don’t agree", intended: "we can agree")
        #expect(curly.suggestion?.hear == "we don’t")
        #expect(curly.suggestion?.write == "we can")
    }

    @Test("treats a case-only word edit as a real correction")
    func caseOnlyCorrection() {
        let plan = CorrectionLearner.plan(heard: "Everything is a lie.", intended: "Everything is a Lie.")
        #expect(plan.suggestion?.hear == "a lie")
        #expect(plan.suggestion?.write == "a Lie")
    }

    @Test("does not discard a case-changing prefix when another word also changes")
    func caseChangingPrefixAndAnotherEdit() {
        let plan = CorrectionLearner.plan(heard: "Everything is a lie.", intended: "EVERYTHING is a line.")
        #expect(plan.suggestion?.hear == "Everything is a lie")
        #expect(plan.suggestion?.write == "EVERYTHING is a line")
    }

    @Test("normalizes decomposed Unicode before learning")
    func nfcNormalization() {
        let decomposed = "caffe\u{300}"
        let plan = CorrectionLearner.plan(heard: "\(decomposed) now", intended: "café now")
        #expect(plan.suggestion?.hear == "caffè now")
        #expect(plan.suggestion?.write == "café now")
    }

    @Test("retains punctuation-only edits as history-only plans")
    func punctuationOnlyHistory() {
        let plan = CorrectionLearner.plan(heard: "Hello world", intended: "Hello, world")
        #expect(plan.suggestion == nil)
        #expect(plan.unavailableReason == .punctuationOnly)
    }

    @Test("rejects insertion and deletion edits")
    func insertionDeletion() {
        #expect(CorrectionLearner.plan(heard: "hello", intended: "hello world").unavailableReason == .insertionOnly)
        #expect(CorrectionLearner.plan(heard: "hello world", intended: "hello").unavailableReason == .deletionOnly)
    }

    @Test("rejects multiline and dictionary syntax")
    func unsafeSyntax() {
        #expect(CorrectionLearner.plan(heard: "hello", intended: "hello\nworld").unavailableReason == .multiline)
        #expect(CorrectionLearner.plan(heard: "hello", intended: "hello -> world").unavailableReason == .dictionarySyntax)
    }

    @Test("rejects edits over the word and character caps")
    func editCaps() {
        let heard = (0..<7).map { "word\($0)" }.joined(separator: " ")
        let intended = (0..<7).map { "other\($0)" }.joined(separator: " ")
        #expect(CorrectionLearner.plan(heard: heard, intended: intended).unavailableReason == .tooManyWords)

        let longHeard = String(repeating: "a", count: 161) + " x"
        let longIntended = String(repeating: "b", count: 161) + " x"
        #expect(CorrectionLearner.plan(heard: longHeard, intended: longIntended).unavailableReason == .tooLong)
    }

    @Test("upsert is idempotent and moves the learned rule to the front")
    func duplicateUpsert() {
        let suggestion = CorrectionRuleSuggestion(hear: "a lie", write: "a line")
        let existing = DictionaryEntry.correction(hear: "other phrase", write: "Other")
        let once = CorrectionLearner.upserting(suggestion, into: [existing])
        let twice = CorrectionLearner.upserting(suggestion, into: once)
        #expect(twice.count == 2)
        #expect(twice.first?.hear == "a lie")
        #expect(twice.first?.write == "a line")
        #expect(twice.first?.id == once.first?.id)
    }

    @Test("upsert replaces conflicting triggers and reenables disabled rules")
    func conflictingAndDisabledUpsert() {
        let disabled = DictionaryEntry(
            kind: .correction, write: "Old", hear: "a lie", isEnabled: false
        )
        let other = DictionaryEntry.correction(hear: "a lie", write: "Other")
        let result = CorrectionLearner.upserting(
            CorrectionRuleSuggestion(hear: "a lie", write: "a line"),
            into: [disabled, other]
        )
        #expect(result.count == 1)
        #expect(result.first?.write == "a line")
        #expect(result.first?.isEnabled == true)
    }
}
