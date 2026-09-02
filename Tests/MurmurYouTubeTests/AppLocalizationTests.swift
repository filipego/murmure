import Foundation
import MurmurUpdateCore
import Testing
@testable import MurmurYouTube

@Suite("App localization")
struct AppLocalizationTests {
    @Test("settings and hub navigation keep their approved order")
    func navigationOrder() {
        #expect(SettingsCategory.allCases == [
            .dictation,
            .shortcuts,
            .microphoneAndSounds,
            .appearance,
            .privacyAndStorage,
            .advancedAndUpdates,
        ])
        #expect(HubSection.allCases == [.home, .dictionary, .snippets, .settings])
        #expect(SettingsCategory.dictation.systemImage == "waveform")
        #expect(HubSection.snippets.systemImage == "text.quote")
    }

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
        #expect(L10n.text("Display language", language: .french) == "Langue d’affichage")
        #expect(L10n.text("Display language", language: .spanish) == "Idioma de la interfaz")
        #expect(L10n.text("Choose display language", language: .french) == "Choisir la langue d’affichage")
        #expect(L10n.text("Choose display language", language: .spanish) == "Elegir el idioma de la interfaz")
        #expect(L10n.text("Language you speak", language: .french) == "Langue que vous parlez")
        #expect(L10n.text("Language you speak", language: .spanish) == "Idioma que hablas")
        #expect(L10n.text("Display language", language: .french) != L10n.text("Language you speak", language: .french))
        #expect(L10n.text("Display language", language: .spanish) != L10n.text("Language you speak", language: .spanish))
        #expect(L10n.text("Settings", language: .french) == "Réglages")
        #expect(L10n.text("Settings", language: .spanish) == "Ajustes")
        #expect(L10n.text("Automatic", language: .french) == "Automatique")
        #expect(L10n.text("Automatic", language: .spanish) == "Automático")
        #expect(L10n.text("External storage ready", language: .french) == "Stockage externe prêt")
        #expect(L10n.text("External storage ready", language: .spanish) == "Almacenamiento externo listo")
        #expect(L10n.text("When should Murmure type?", language: .french) == "Quand Murmure doit-il écrire ?")
        #expect(L10n.text("When should Murmure type?", language: .spanish) == "¿Cuándo debe escribir Murmure?")
        #expect(L10n.text("After I finish speaking", language: .french) == "Après avoir fini de parler")
        #expect(L10n.text("After I finish speaking", language: .spanish) == "Después de terminar de hablar")
        #expect(L10n.text("While I’m speaking", language: .french) == "Pendant que je parle")
        #expect(L10n.text("While I’m speaking", language: .spanish) == "Mientras hablo")
        #expect(L10n.text("Live typing is ready with Apple.", language: .french) == "La saisie en direct est prête avec Apple.")
        #expect(L10n.text("Live typing is ready with Apple.", language: .spanish) == "La escritura en directo está lista con Apple.")
        #expect(L10n.text("Compare Mode shows both engines, so Murmure will not type into the destination.", language: .french) == "Le mode Comparaison affiche les deux moteurs, donc Murmure n’écrira pas dans la destination.")
        #expect(L10n.text("Compare Mode shows both engines, so Murmure will not type into the destination.", language: .spanish) == "El modo Comparación muestra ambos motores, así que Murmure no escribirá en el destino.")
        #expect(L10n.text("Murmure will type after you finish speaking.", language: .french) == "Murmure écrira après que vous aurez fini de parler.")
        #expect(L10n.text("Murmure will type after you finish speaking.", language: .spanish) == "Murmure escribirá cuando termines de hablar.")
        #expect(L10n.text("Live typing requires Apple and a selected spoken language. With these settings, Murmure will type after you finish.", language: .french) == "La saisie en direct nécessite Apple et une langue parlée sélectionnée. Avec ces réglages, Murmure écrira après que vous aurez fini de parler.")
        #expect(L10n.text("Live typing requires Apple and a selected spoken language. With these settings, Murmure will type after you finish.", language: .spanish) == "La escritura en directo requiere Apple y un idioma hablado seleccionado. Con estos ajustes, Murmure escribirá cuando termines de hablar.")
        #expect(L10n.text("Live typing stopped because the destination changed. Your final text is saved in History.", language: .french) == "La saisie en direct s’est arrêtée car la destination a changé. Votre texte final est enregistré dans l’historique.")
        #expect(L10n.text("Live typing stopped because the destination changed. Your final text is saved in History.", language: .spanish) == "La escritura en directo se detuvo porque cambió el destino. Tu texto final se guardó en el historial.")
        #expect(L10n.text("Live typing stopped before temporary text could be safely removed. Check the destination; the recording is available in recovery.", language: .french) == "La saisie en direct s’est arrêtée avant que le texte temporaire puisse être retiré en toute sécurité. Vérifiez la destination ; l’enregistrement est disponible dans la récupération.")
        #expect(L10n.text("Live typing stopped before temporary text could be safely removed. Check the destination; the recording is available in recovery.", language: .spanish) == "La escritura en directo se detuvo antes de poder quitar el texto temporal de forma segura. Revisa el destino; la grabación está disponible en recuperación.")
        let issues = try L10n.catalogIssues()
        #expect(issues.isEmpty, Comment(rawValue: issues.joined(separator: "\n")))
    }

    @Test("available update status formats a numeric build as text")
    func availableUpdateStatusFormatting() {
        let version = AppVersion(marketing: "0.1.17", build: 17)

        #expect(UpdateStatusText.available(version, language: .english) ==
            "Version 0.1.17 (17) is ready to install.")
        #expect(UpdateStatusText.available(version, language: .french) ==
            "La version 0.1.17 (17) est prête à être installée.")
        #expect(UpdateStatusText.available(version, language: .spanish) ==
            "La versión 0.1.17 (17) está lista para instalarse.")
    }
}
