import Foundation
import MurmurSessionCore
import Testing
@testable import MurmurYouTube

@Suite("Transcription languages")
struct TranscriptionLanguageTests {
    @Test("the three explicit choices use stable language identifiers")
    func stableSelections() {
        #expect(TranscriptionLanguageOption.english.selection == .locale(identifier: "en"))
        #expect(TranscriptionLanguageOption.spanish.selection == .locale(identifier: "es"))
        #expect(TranscriptionLanguageOption.french.selection == .locale(identifier: "fr"))
        #expect(TranscriptionLanguageOption.systemDefault.selection == .systemDefault)
    }

    @Test("automatic plus the verified Parakeet set are all available")
    func verifiedLanguageSet() {
        let codes = Set(TranscriptionLanguageOption.allCases.compactMap(\.languageCode))
        #expect(codes == Set([
            "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu",
            "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
        ]))
        #expect(TranscriptionLanguageOption.allCases.count == 26)
    }

    @Test("automatic recognition always uses the multilingual engine")
    func automaticEngine() {
        #expect(resolvedEngineChoice(preferred: .apple, language: .systemDefault) == .parakeet)
        #expect(resolvedEngineChoice(
            preferred: .apple,
            language: .locale(identifier: "fr")
        ) == .apple)
    }

    @Test("system default resolves to an equivalent supported locale")
    func systemDefaultResolution() {
        let resolved = LanguageResolutionPolicy.resolve(
            selection: .systemDefault,
            systemLocaleIdentifier: "fr-CA",
            supportedLocaleIdentifiers: ["en-US", "fr-FR", "es-ES"]
        )

        #expect(resolved == "fr-FR")
    }

    @Test("an explicit language resolves without an English fallback")
    func explicitResolution() {
        #expect(LanguageResolutionPolicy.resolve(
            selection: .locale(identifier: "es"),
            systemLocaleIdentifier: "en-US",
            supportedLocaleIdentifiers: ["en-US", "es-MX"]
        ) == "es-MX")

        #expect(LanguageResolutionPolicy.resolve(
            selection: .locale(identifier: "fr"),
            systemLocaleIdentifier: "en-US",
            supportedLocaleIdentifiers: ["en-US", "es-MX"]
        ) == nil)
    }

    @Test("old settings decode as system default")
    func legacySettings() throws {
        let data = Data(#"{"pushToTalkKey":"fn","engine":"apple","compareMode":false,"cleanupEnabled":true,"smartCleanup":false,"soundEnabled":true}"#.utf8)
        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)

        #expect(snapshot.resolvedTranscriptionLanguage == .systemDefault)
    }

    @Test("an explicit language survives settings decoding")
    func explicitSettings() throws {
        let data = Data(#"{"pushToTalkKey":"fn","engine":"apple","compareMode":false,"cleanupEnabled":true,"smartCleanup":false,"soundEnabled":true,"transcriptionLanguage":"spanish"}"#.utf8)
        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)

        #expect(snapshot.resolvedTranscriptionLanguage == .spanish)
    }

    @Test("old history decodes without language metadata")
    func legacyHistory() throws {
        let data = Data(#"{"date":0,"engine":"Apple","audioSeconds":1,"processSeconds":0.1,"text":"Hola."}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let run = try decoder.decode(DictationRun.self, from: data)
        #expect(run.language == nil)
        #expect(run.appliedSnippet == nil)
    }

    @Test("history preserves its selected language")
    func languageHistory() throws {
        let run = DictationRun(
            date: Date(timeIntervalSince1970: 1),
            engine: "Parakeet",
            language: .locale(identifier: "es"),
            audioSeconds: 2,
            processSeconds: 0.2,
            text: "Hola."
        )

        let restored = try JSONDecoder().decode(
            DictationRun.self,
            from: JSONEncoder().encode(run)
        )
        #expect(restored.language == .locale(identifier: "es"))
    }
}

@Suite("Multilingual deterministic cleanup")
struct MultilingualCleanupTests {
    @Test("English cleanup keeps the existing behavior")
    func english() async {
        let output = await RuleBasedFormatter(profile: .english).format(
            "um hello new paragraph this is fine"
        )
        #expect(output == "Hello\n\nThis is fine.")
    }

    @Test("Spanish cleanup removes Spanish fillers and spoken punctuation")
    func spanish() async {
        let output = await RuleBasedFormatter(profile: .spanish).format(
            "eh hola nueva línea cómo estás"
        )
        #expect(output == "Hola\nCómo estás.")
    }

    @Test("French cleanup preserves accents and applies French commands")
    func french() async {
        let output = await RuleBasedFormatter(profile: .french).format(
            "euh déjà nouveau paragraphe très bien"
        )
        #expect(output == "Déjà\n\nTrès bien.")
    }

    @Test("unknown languages receive neutral cleanup only")
    func neutral() async {
        let output = await RuleBasedFormatter(profile: .neutral).format(
            "  um merhaba   dünya  "
        )
        #expect(output == "um merhaba dünya")
    }

    @Test("automatic recognition never applies English cleanup assumptions")
    func automaticCleanup() async {
        let output = await RuleBasedFormatter(
            profile: TranscriptionLanguageOption.systemDefault.cleanupProfile
        ).format("  um bonjour   le monde  ")
        #expect(output == "um bonjour le monde")
    }

    @Test("cleanup returns composed Unicode")
    func normalization() async {
        let decomposed = "de\u{301}ja\u{300}"
        let output = await RuleBasedFormatter(profile: .french).format(decomposed)
        #expect(output == "Déjà.")
        #expect(output == output.precomposedStringWithCanonicalMapping)
    }
}
