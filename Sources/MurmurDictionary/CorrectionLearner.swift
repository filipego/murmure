import Foundation

/// A correction pair inferred from one edited transcript.
public struct CorrectionRuleSuggestion: Equatable, Hashable, Codable, Sendable {
    public let hear: String
    public let write: String

    public init(hear: String, write: String) {
        self.hear = hear
        self.write = write
    }
}

/// Why a correction was retained in history without producing a dictionary rule.
public enum CorrectionLearningUnavailableReason: String, Equatable, Codable, Sendable {
    case blankIntended
    case insertionOnly
    case deletionOnly
    case punctuationOnly
    case multiline
    case dictionarySyntax
    case tooManyWords
    case tooLong
    case noWordChange
    case insufficientContext
    case validationFailed
}

/// The deterministic result of comparing one heard transcript with its edited text.
public struct CorrectionLearningPlan: Equatable, Sendable {
    public let suggestion: CorrectionRuleSuggestion?
    public let unavailableReason: CorrectionLearningUnavailableReason?

    public init(
        suggestion: CorrectionRuleSuggestion? = nil,
        unavailableReason: CorrectionLearningUnavailableReason? = nil
    ) {
        self.suggestion = suggestion
        self.unavailableReason = unavailableReason
    }

    /// Alias useful to callers that only need to explain a history-only correction.
    public var reason: CorrectionLearningUnavailableReason? { unavailableReason }
}

/// Infers a narrowly-scoped, validated correction from an edited transcript.
public enum CorrectionLearner {
    private static let maximumWords = 6
    private static let maximumCharacters = 160

    private struct Word {
        let text: String
        let range: Range<String.Index>
    }

    public static func plan(heard: String, intended: String) -> CorrectionLearningPlan {
        let heard = normalize(heard)
        let intended = normalize(intended)

        guard !intended.isEmpty else {
            return CorrectionLearningPlan(unavailableReason: .blankIntended)
        }
        if heard.contains("\n") || heard.contains("\r") || intended.contains("\n") || intended.contains("\r") {
            return CorrectionLearningPlan(unavailableReason: .multiline)
        }
        if containsDictionarySyntax(heard) || containsDictionarySyntax(intended) {
            return CorrectionLearningPlan(unavailableReason: .dictionarySyntax)
        }
        if heard == intended {
            return CorrectionLearningPlan(unavailableReason: .noWordChange)
        }

        let heardWords = words(in: heard)
        let intendedWords = words(in: intended)
        let commonWordCount = min(heardWords.count, intendedWords.count)

        var prefix = 0
        while prefix < commonWordCount && heardWords[prefix].text == intendedWords[prefix].text {
            prefix += 1
        }
        var suffix = 0
        while suffix < commonWordCount - prefix {
            let heardWord = heardWords[heardWords.count - suffix - 1]
            let intendedWord = intendedWords[intendedWords.count - suffix - 1]
            guard heardWord.text == intendedWord.text else { break }
            suffix += 1
        }

        let heardEnd = heardWords.count - suffix
        let intendedEnd = intendedWords.count - suffix
        let heardChanged = heardEnd - prefix
        let intendedChanged = intendedEnd - prefix
        if heardChanged == 0 && intendedChanged == 0 {
            return CorrectionLearningPlan(unavailableReason: .punctuationOnly)
        }
        if heardChanged == 0 { return CorrectionLearningPlan(unavailableReason: .insertionOnly) }
        if intendedChanged == 0 { return CorrectionLearningPlan(unavailableReason: .deletionOnly) }
        if heardChanged != intendedChanged {
            return CorrectionLearningPlan(unavailableReason: heardChanged < intendedChanged ? .insertionOnly : .deletionOnly)
        }

        // A one-word global rewrite is too broad. Prefer the immediately preceding
        // equal word, then the following one (the latter handles a repeated token).
        var selectedStart = prefix
        var selectedEnd = heardEnd
        if selectedEnd - selectedStart == 1 {
            if selectedStart > 0 {
                selectedStart -= 1
            } else if selectedEnd < heardWords.count {
                selectedEnd += 1
            } else {
                return CorrectionLearningPlan(unavailableReason: .insufficientContext)
            }
        }

        let wordCount = selectedEnd - selectedStart
        guard wordCount <= maximumWords else {
            return CorrectionLearningPlan(unavailableReason: .tooManyWords)
        }
        let intendedStart = selectedStart
        let intendedSelectedEnd = intendedStart + wordCount
        guard intendedSelectedEnd <= intendedWords.count else {
            return CorrectionLearningPlan(unavailableReason: .validationFailed)
        }

        let hearRange = heardWords[selectedStart].range.lowerBound..<heardWords[selectedEnd - 1].range.upperBound
        let writeRange = intendedWords[intendedStart].range.lowerBound..<intendedWords[intendedSelectedEnd - 1].range.upperBound
        let suggestion = CorrectionRuleSuggestion(
            hear: String(heard[hearRange]),
            write: String(intended[writeRange])
        )
        guard suggestion.hear.count <= maximumCharacters && suggestion.write.count <= maximumCharacters else {
            return CorrectionLearningPlan(unavailableReason: .tooLong)
        }
        guard !suggestion.hear.isEmpty, !suggestion.write.isEmpty else {
            return CorrectionLearningPlan(unavailableReason: .validationFailed)
        }

        // Validate against the complete transcript, not merely the selected span. This
        // prevents a rule whose optional separators or boundaries alter unrelated text.
        let corrector = DictionaryCorrector(entries: [
            .correction(hear: suggestion.hear, write: suggestion.write)
        ])
        guard corrector.apply(to: heard).text == intended else {
            return CorrectionLearningPlan(unavailableReason: .validationFailed)
        }
        return CorrectionLearningPlan(suggestion: suggestion)
    }

    /// Inserts a suggestion at the front, replacing every existing rule with the same
    /// normalized trigger. Existing UUIDs are retained where possible so a disabled rule
    /// is re-enabled rather than duplicated.
    public static func upserting(_ suggestion: CorrectionRuleSuggestion, into entries: [DictionaryEntry]) -> [DictionaryEntry] {
        let hear = normalize(suggestion.hear)
        let write = normalize(suggestion.write)
        guard !hear.isEmpty, !write.isEmpty else { return entries }

        var retained: [DictionaryEntry] = []
        var existingID: UUID?
        for entry in entries {
            guard entry.kind == .correction,
                  equivalent(normalize(entry.hear), hear) else {
                retained.append(entry)
                continue
            }
            existingID = existingID ?? entry.id
        }
        let replacement = DictionaryEntry(
            id: existingID ?? UUID(), kind: .correction, write: write, hear: hear, isEnabled: true
        )
        return [replacement] + retained
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        lhs.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(
            rhs.precomposedStringWithCanonicalMapping
        ) == .orderedSame
    }

    private static func containsDictionarySyntax(_ text: String) -> Bool {
        text.contains("->") || text.hasPrefix("#")
    }

    private static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard isWordCharacter(text[index]) else {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex {
                if isWordCharacter(text[index]) {
                    index = text.index(after: index)
                    continue
                }
                // Apostrophes between two word characters are part of a contraction.
                if isApostrophe(text[index]) {
                    let afterApostrophe = text.index(after: index)
                    guard afterApostrophe < text.endIndex,
                          isWordCharacter(text[afterApostrophe]) else { break }
                    index = afterApostrophe
                    continue
                }
                break
            }
            result.append(Word(text: String(text[start..<index]), range: start..<index))
        }
        return result
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            CharacterSet.letters.contains($0)
                || CharacterSet.decimalDigits.contains($0)
                || CharacterSet.nonBaseCharacters.contains($0)
        }
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’"
    }
}
