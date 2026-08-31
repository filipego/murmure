import Foundation

/// The cleanup pass between raw transcription and injection.
///
/// Raw speech-to-text output is full of filler
/// words, missing punctuation, and spoken corrections. Swapping in an LLM-backed
/// formatter (Apple Foundation Models on-device, or Claude for the high-quality tier)
/// is the point of keeping this behind a protocol.
protocol TextFormatter: Sendable {
    func format(_ raw: String) async -> String
}

/// Deterministic, zero-latency cleanup. Good enough to be useful on its own and always
/// the fallback when a model-backed formatter is unavailable or times out.
struct RuleBasedFormatter: TextFormatter {
    private let profile: CleanupProfile

    init(profile: CleanupProfile = .english) {
        self.profile = profile
    }

    func format(_ raw: String) async -> String {
        var text = raw.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        text = stripFillers(from: text, fillers: profile.fillers)
        text = applySpokenPunctuation(to: text, phrases: profile.spokenPunctuation)
        text = collapseWhitespace(in: text)
        if profile.appliesSentenceFormatting {
            text = capitalizeSentences(in: text)
            text = ensureTerminalPunctuation(in: text)
        }

        return text.precomposedStringWithCanonicalMapping
    }

    private func stripFillers(from text: String, fillers: [String]) -> String {
        var result = text
        for filler in fillers {
            // Match the filler as a whole word, plus a trailing comma if the ASR added one.
            let pattern = "(?i)(?<![\\w'])\(filler)\\b,?"
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return result
    }

    private func applySpokenPunctuation(to text: String, phrases: [(String, String)]) -> String {
        var result = text
        for (phrase, replacement) in phrases {
            result = result.replacingOccurrences(
                of: "(?i)\\b\(phrase)\\b",
                with: replacement,
                options: .regularExpression
            )
        }
        return result
    }

    private func collapseWhitespace(in text: String) -> String {
        text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: " +([,.!?;:])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func capitalizeSentences(in text: String) -> String {
        var result = ""
        var capitalizeNext = true

        for character in text {
            if capitalizeNext, character.isLetter {
                result.append(Character(character.uppercased()))
                capitalizeNext = false
            } else {
                result.append(character)
                if ".!?\n".contains(character) { capitalizeNext = true }
            }
        }
        return result
    }

    private func ensureTerminalPunctuation(in text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber else { return text }
        return text + "."
    }
}

struct CleanupProfile: Sendable {
    let locale: Locale?
    let fillers: [String]
    let spokenPunctuation: [(String, String)]
    let appliesSentenceFormatting: Bool

    static let english = CleanupProfile(
        locale: Locale(identifier: "en"),
        fillers: ["um", "uh", "erm", "uhm", "hmm", "mhm"],
        spokenPunctuation: [
            ("new paragraph", "\n\n"), ("new line", "\n"),
            ("open paren", " ("), ("close paren", ") "),
        ],
        appliesSentenceFormatting: true
    )

    static let spanish = CleanupProfile(
        locale: Locale(identifier: "es"),
        fillers: ["eh", "em", "este", "mmm"],
        spokenPunctuation: [
            ("nuevo párrafo", "\n\n"), ("nueva línea", "\n"),
            ("abre paréntesis", " ("), ("cierra paréntesis", ") "),
        ],
        appliesSentenceFormatting: true
    )

    static let french = CleanupProfile(
        locale: Locale(identifier: "fr"),
        fillers: ["euh", "heu", "hum"],
        spokenPunctuation: [
            ("nouveau paragraphe", "\n\n"), ("nouvelle ligne", "\n"),
            ("ouvre parenthèse", " ("), ("ferme parenthèse", ") "),
        ],
        appliesSentenceFormatting: true
    )

    static let neutral = CleanupProfile(
        locale: nil,
        fillers: [],
        spokenPunctuation: [],
        appliesSentenceFormatting: false
    )

    static func forLocale(_ locale: Locale) -> CleanupProfile {
        switch locale.language.languageCode?.identifier {
        case "en": .english
        case "es": .spanish
        case "fr": .french
        default: .neutral
        }
    }
}

/// No-op formatter, for comparing raw engine output against the cleanup pass.
struct PassthroughFormatter: TextFormatter {
    func format(_ raw: String) async -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
