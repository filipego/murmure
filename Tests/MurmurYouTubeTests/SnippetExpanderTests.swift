import Foundation
import Testing
@testable import MurmurYouTube

@Suite("Local snippet expansion")
struct SnippetExpanderTests {
    @Test("an enabled whole utterance expands exactly once")
    func exactExpansion() {
        let snippet = SnippetEntry(trigger: "my address", replacement: "12 Rue de Rivoli")

        let result = SnippetExpander(entries: [snippet]).expand("  My address  ")

        #expect(result.text == "12 Rue de Rivoli")
        #expect(result.applied == AppliedSnippet(id: snippet.id, trigger: "my address"))
    }

    @Test("normal trailing sentence punctuation does not prevent a whole-utterance expansion")
    func trailingPunctuationExpansion() {
        let snippet = SnippetEntry(trigger: "contact card", replacement: "Private replacement")

        for utterance in ["Contact card.", "contact card!", "contact card?", "contact card,"] {
            let result = SnippetExpander(entries: [snippet]).expand(utterance)

            #expect(result.text == "Private replacement")
            #expect(result.applied?.id == snippet.id)
        }
    }

    @Test("Insert deliberately invokes a whole-utterance snippet")
    func deliberateCommandExpansion() {
        let snippet = SnippetEntry(trigger: "contact card", replacement: "Private replacement")

        for utterance in [
            "Insert, contact card.",
            "insert contact card",
            "INSERT: CONTACT CARD!",
        ] {
            let result = SnippetExpander(entries: [snippet], language: .english).expand(utterance)

            #expect(result.text == "Private replacement")
            #expect(result.applied?.id == snippet.id)
        }
    }

    @Test("Insert still requires an exact trigger after the command")
    func deliberateCommandRejectsAddedWords() {
        let snippet = SnippetEntry(trigger: "contact card", replacement: "Private replacement")

        let result = SnippetExpander(entries: [snippet], language: .english).expand(
            "Insert, please use contact card."
        )

        #expect(result.text == "Insert, please use contact card.")
        #expect(result.applied == nil)
    }

    @Test("Insert expands its trigger and preserves the rest of the sentence")
    func deliberateCommandExpansionInsideSentence() {
        let snippet = SnippetEntry(trigger: "contact card", replacement: "Saved contact")

        let result = SnippetExpander(entries: [snippet], language: .english).expand(
            "Insert contact card, and send a letter there."
        )

        #expect(result.text == "Saved contact, and send a letter there.")
        #expect(result.applied == AppliedSnippet(id: snippet.id, trigger: "contact card"))
    }

    @Test("Insert chooses the longest matching trigger before trailing speech")
    func deliberateCommandUsesLongestTrigger() {
        let short = SnippetEntry(trigger: "contact", replacement: "Short")
        let long = SnippetEntry(trigger: "contact card", replacement: "Long")

        let result = SnippetExpander(entries: [short, long], language: .english).expand(
            "Insert contact card and continue"
        )

        #expect(result.text == "Long and continue")
        #expect(result.applied == AppliedSnippet(id: long.id, trigger: "contact card"))
    }

    @Test("the retired Murmure add phrase is no longer treated as a command")
    func retiredCommandDoesNotInvokeSnippet() {
        let snippet = SnippetEntry(trigger: "contact card", replacement: "Saved contact")

        let result = SnippetExpander(entries: [snippet]).expand("Murmure add, contact card")

        #expect(result.text == "Murmure add, contact card")
        #expect(result.applied == nil)
    }

    @Test("every explicit spoken language has one localized command")
    func everyLanguageHasCommand() {
        let expected: [TranscriptionLanguageOption: String] = [
            .english: "Insert", .spanish: "Inserta", .french: "Insère",
            .bulgarian: "Вмъкни", .croatian: "Umetni", .czech: "Vlož",
            .danish: "Indsæt", .dutch: "Voeg", .estonian: "Sisesta",
            .finnish: "Lisää", .german: "Einfügen", .greek: "Εισαγωγή",
            .hungarian: "Illeszd", .italian: "Inserisci", .latvian: "Ievieto",
            .lithuanian: "Įterpk", .maltese: "Daħħal", .polish: "Wstaw",
            .portuguese: "Insira", .romanian: "Inserează", .russian: "Вставь",
            .slovak: "Vlož", .slovenian: "Vstavi", .swedish: "Infoga",
            .ukrainian: "Встав",
        ]

        #expect(expected.count == TranscriptionLanguageOption.allCases.count - 1)
        for (language, command) in expected {
            #expect(SnippetCommandLexicon.commands(for: language) == [command])
        }
    }

    @Test("Automatic accepts every localized command")
    func automaticAcceptsEveryCommand() {
        for language in TranscriptionLanguageOption.allCases where language != .systemDefault {
            let command = SnippetCommandLexicon.primaryCommand(for: language)
            let snippet = SnippetEntry(trigger: "saved phrase", replacement: "Expanded")
            let result = SnippetExpander(entries: [snippet], language: .systemDefault)
                .expand("\(command) saved phrase, continue")

            #expect(result.text == "Expanded, continue")
            #expect(result.applied?.id == snippet.id)
        }
    }

    @Test("an explicit language rejects a different language command")
    func explicitLanguageRejectsOtherCommand() {
        let snippet = SnippetEntry(trigger: "mon adresse", replacement: "Adresse")
        let result = SnippetExpander(entries: [snippet], language: .french)
            .expand("Inserta mon adresse")

        #expect(result.text == "Inserta mon adresse")
        #expect(result.applied == nil)
    }

    @Test("localized commands require a word boundary")
    func commandRequiresBoundary() {
        let snippet = SnippetEntry(trigger: "contact", replacement: "Expanded")
        let result = SnippetExpander(entries: [snippet], language: .english)
            .expand("Inserted contact")

        #expect(result.text == "Inserted contact")
        #expect(result.applied == nil)
    }

    @Test("localized commands use canonical Unicode equivalence")
    func commandUnicodeNormalization() {
        let snippet = SnippetEntry(trigger: "mon adresse", replacement: "Adresse")
        let decomposed = "Inse\u{300}re mon adresse"
        let result = SnippetExpander(entries: [snippet], language: .french).expand(decomposed)

        #expect(result.text == "Adresse")
        #expect(result.applied?.id == snippet.id)
    }

    @Test("trailing punctuation tolerance never permits added words")
    func punctuationDoesNotPermitAddedWords() {
        let snippet = SnippetEntry(trigger: "contact card", replacement: "Private replacement")

        let result = SnippetExpander(entries: [snippet]).expand("Use contact card.")

        #expect(result.text == "Use contact card.")
        #expect(result.applied == nil)
    }

    @Test("a trigger inside ordinary prose never expands")
    func noSubstringExpansion() {
        let snippet = SnippetEntry(trigger: "my address", replacement: "12 Rue de Rivoli")

        let result = SnippetExpander(entries: [snippet]).expand("Please send this to my address today.")

        #expect(result.text == "Please send this to my address today.")
        #expect(result.applied == nil)
    }

    @Test("disabled entries and later duplicates do not win")
    func enabledOrdering() {
        let disabled = SnippetEntry(trigger: "signature", replacement: "Wrong", isEnabled: false)
        let first = SnippetEntry(trigger: "signature", replacement: "First")
        let later = SnippetEntry(trigger: "SIGNATURE", replacement: "Later")

        let result = SnippetExpander(entries: [disabled, first, later]).expand("Signature")

        #expect(result.text == "First")
        #expect(result.applied?.id == first.id)
    }

    @Test("Unicode triggers are canonically equivalent and replacements may be multiline")
    func unicodeAndMultiline() {
        let snippet = SnippetEntry(
            trigger: "café",
            replacement: "Café de Flore\n172 Boulevard Saint-Germain"
        )
        let decomposed = "cafe\u{301}"

        let result = SnippetExpander(entries: [snippet]).expand(decomposed)

        #expect(result.text == "Café de Flore\n172 Boulevard Saint-Germain")
        #expect(result.text.precomposedStringWithCanonicalMapping == result.text)
    }

    @Test("validation rejects empty values and duplicate normalized triggers")
    func validation() {
        let existing = SnippetEntry(trigger: "Résumé", replacement: "One")

        #expect(SnippetValidator.validate(trigger: " ", replacement: "value", entries: []) == .emptyTrigger)
        #expect(SnippetValidator.validate(trigger: "hello", replacement: "", entries: []) == .emptyReplacement)
        #expect(SnippetValidator.validate(
            trigger: "re\u{301}sume\u{301}",
            replacement: "Two",
            entries: [existing]
        ) == .duplicateTrigger)
    }

    @Test("entries and applied metadata survive JSON round trips")
    func codable() throws {
        let entry = SnippetEntry(trigger: "saludo", replacement: "¡Hola!")
        let restored = try JSONDecoder().decode(
            SnippetEntry.self,
            from: JSONEncoder().encode(entry)
        )

        #expect(restored == entry)
        #expect(try JSONDecoder().decode(
            AppliedSnippet.self,
            from: JSONEncoder().encode(AppliedSnippet(id: entry.id, trigger: entry.trigger))
        ) == AppliedSnippet(id: entry.id, trigger: entry.trigger))
    }
}
