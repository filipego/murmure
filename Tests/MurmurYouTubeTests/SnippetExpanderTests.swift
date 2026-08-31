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
