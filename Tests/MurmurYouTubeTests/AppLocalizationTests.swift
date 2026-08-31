import Foundation
import Testing
@testable import MurmurYouTube

@Suite("App localization")
struct AppLocalizationTests {
    @Test("interface languages use stable identifiers and native names")
    func stableLanguages() {
        #expect(AppLanguage.english.rawValue == "en")
        #expect(AppLanguage.french.rawValue == "fr")
        #expect(AppLanguage.spanish.rawValue == "es")
        #expect(AppLanguage.english.nativeName == "English")
        #expect(AppLanguage.french.nativeName == "Français")
        #expect(AppLanguage.spanish.nativeName == "Español")
    }

    @Test("the initial interface language follows a supported Mac language")
    func preferredLanguage() {
        #expect(AppLanguage.preferred(from: ["fr-CA", "en-US"]) == .french)
        #expect(AppLanguage.preferred(from: ["es-MX", "en-US"]) == .spanish)
        #expect(AppLanguage.preferred(from: ["de-DE", "it-IT"]) == .english)
    }

    @Test("an explicit interface language persists without touching dictation language")
    @MainActor
    func persistenceIsIndependent() {
        let suite = "AppLocalizationTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = AppLanguageStore(
            defaults: defaults,
            key: "test.appLanguage",
            preferredLanguages: ["en-US"]
        )

        store.language = .french

        #expect(AppLanguageStore(
            defaults: defaults,
            key: "test.appLanguage",
            preferredLanguages: ["en-US"]
        ).language == .french)
        #expect(TranscriptionLanguageOption.spanish == .spanish)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("all language catalogs contain the same keys and format placeholders")
    func completeCatalogs() throws {
        #expect(L10n.text("Home", language: .english) == "Home")
        #expect(L10n.text("Home", language: .french) == "Accueil")
        #expect(L10n.text("Home", language: .spanish) == "Inicio")
        #expect(L10n.text("App language", language: .french) == "Langue de l’app")
        #expect(L10n.text("App language", language: .spanish) == "Idioma de la app")
        let issues = try L10n.catalogIssues()
        #expect(issues.isEmpty, Comment(rawValue: issues.joined(separator: "\n")))
    }
}
