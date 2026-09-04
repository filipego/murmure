import Foundation

enum SnippetCommandLexicon {
    private static let localizedCommands: [TranscriptionLanguageOption: String] = [
        .english: "Insert",
        .spanish: "Inserta",
        .french: "Insère",
        .bulgarian: "Вмъкни",
        .croatian: "Umetni",
        .czech: "Vlož",
        .danish: "Indsæt",
        .dutch: "Voeg",
        .estonian: "Sisesta",
        .finnish: "Lisää",
        .german: "Einfügen",
        .greek: "Εισαγωγή",
        .hungarian: "Illeszd",
        .italian: "Inserisci",
        .latvian: "Ievieto",
        .lithuanian: "Įterpk",
        .maltese: "Daħħal",
        .polish: "Wstaw",
        .portuguese: "Insira",
        .romanian: "Inserează",
        .russian: "Вставь",
        .slovak: "Vlož",
        .slovenian: "Vstavi",
        .swedish: "Infoga",
        .ukrainian: "Встав",
    ]

    static func commands(for language: TranscriptionLanguageOption) -> [String] {
        if language != .systemDefault {
            return localizedCommands[language].map { [$0] } ?? []
        }

        var seen = Set<String>()
        return TranscriptionLanguageOption.allCases.compactMap { option in
            guard let command = localizedCommands[option] else { return nil }
            let key = comparisonKey(command)
            return seen.insert(key).inserted ? command : nil
        }
    }

    static func primaryCommand(for language: TranscriptionLanguageOption) -> String {
        localizedCommands[language] ?? localizedCommands[.english] ?? "Insert"
    }

    static func comparisonKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
