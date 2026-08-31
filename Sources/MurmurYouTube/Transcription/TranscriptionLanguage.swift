import Foundation
import MurmurSessionCore
import Observation
import Speech

enum TranscriptionLanguageOption: String, CaseIterable, Codable, Sendable, Hashable {
    case systemDefault
    case english
    case spanish
    case french
    case bulgarian
    case croatian
    case czech
    case danish
    case dutch
    case estonian
    case finnish
    case german
    case greek
    case hungarian
    case italian
    case latvian
    case lithuanian
    case maltese
    case polish
    case portuguese
    case romanian
    case russian
    case slovak
    case slovenian
    case swedish
    case ukrainian

    var displayName: String {
        switch self {
        case .systemDefault: "Automatic"
        case .english: "English"
        case .spanish: "Spanish"
        case .french: "French"
        case .bulgarian: "Bulgarian"
        case .croatian: "Croatian"
        case .czech: "Czech"
        case .danish: "Danish"
        case .dutch: "Dutch"
        case .estonian: "Estonian"
        case .finnish: "Finnish"
        case .german: "German"
        case .greek: "Greek"
        case .hungarian: "Hungarian"
        case .italian: "Italian"
        case .latvian: "Latvian"
        case .lithuanian: "Lithuanian"
        case .maltese: "Maltese"
        case .polish: "Polish"
        case .portuguese: "Portuguese"
        case .romanian: "Romanian"
        case .russian: "Russian"
        case .slovak: "Slovak"
        case .slovenian: "Slovenian"
        case .swedish: "Swedish"
        case .ukrainian: "Ukrainian"
        }
    }

    var languageCode: String? {
        switch self {
        case .systemDefault: nil
        case .english: "en"
        case .spanish: "es"
        case .french: "fr"
        case .bulgarian: "bg"
        case .croatian: "hr"
        case .czech: "cs"
        case .danish: "da"
        case .dutch: "nl"
        case .estonian: "et"
        case .finnish: "fi"
        case .german: "de"
        case .greek: "el"
        case .hungarian: "hu"
        case .italian: "it"
        case .latvian: "lv"
        case .lithuanian: "lt"
        case .maltese: "mt"
        case .polish: "pl"
        case .portuguese: "pt"
        case .romanian: "ro"
        case .russian: "ru"
        case .slovak: "sk"
        case .slovenian: "sl"
        case .swedish: "sv"
        case .ukrainian: "uk"
        }
    }

    var selection: TranscriptionLanguageSelection {
        languageCode.map { .locale(identifier: $0) } ?? .systemDefault
    }

    var requestedLocale: Locale {
        switch selection {
        case .systemDefault: .current
        case .locale(let identifier): Locale(identifier: identifier)
        }
    }

    var cleanupProfile: CleanupProfile {
        switch self {
        case .systemDefault: .neutral
        case .english: .english
        case .spanish: .spanish
        case .french: .french
        default: .neutral
        }
    }

    static func explicitSystemLanguage(locale: Locale = .current) -> Self {
        guard let code = locale.language.languageCode?.identifier else { return .english }
        return allCases.first { $0.languageCode == code } ?? .english
    }
}

enum LanguageResolutionPolicy {
    static func resolve(
        selection: TranscriptionLanguageSelection,
        systemLocaleIdentifier: String,
        supportedLocaleIdentifiers: [String]
    ) -> String? {
        let requested = switch selection {
        case .systemDefault: systemLocaleIdentifier
        case .locale(let identifier): identifier
        }
        let requestedLanguage = languageCode(requested)

        return supportedLocaleIdentifiers.first { candidate in
            candidate.caseInsensitiveCompare(requested) == .orderedSame
        } ?? supportedLocaleIdentifiers.first { languageCode($0) == requestedLanguage }
    }

    private static func languageCode(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", maxSplits: 1)
            .first
            .map { String($0).lowercased() } ?? identifier.lowercased()
    }
}

struct SpeechLanguageAvailability: Equatable, Sendable {
    let resolvedLocaleIdentifier: String?
    let isInstalled: Bool

    var isSupported: Bool { resolvedLocaleIdentifier != nil }
}

@MainActor
@Observable
final class SpeechLanguageCatalog {
    static let shared = SpeechLanguageCatalog()

    private(set) var availability: [TranscriptionLanguageOption: SpeechLanguageAvailability] = [:]
    private(set) var isLoading = false

    private init() {}

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        let supportedIDs = supported.map { $0.identifier(.bcp47) }
        let installedIDs = Set(installed.map { $0.identifier(.bcp47).lowercased() })

        availability = Dictionary(uniqueKeysWithValues: TranscriptionLanguageOption.allCases.map { option in
            let resolved = LanguageResolutionPolicy.resolve(
                selection: option.selection,
                systemLocaleIdentifier: Locale.current.identifier(.bcp47),
                supportedLocaleIdentifiers: supportedIDs
            )
            return (option, SpeechLanguageAvailability(
                resolvedLocaleIdentifier: resolved,
                isInstalled: resolved.map { installedIDs.contains($0.lowercased()) } ?? false
            ))
        })
    }

    func status(for option: TranscriptionLanguageOption) -> SpeechLanguageAvailability? {
        availability[option]
    }
}
