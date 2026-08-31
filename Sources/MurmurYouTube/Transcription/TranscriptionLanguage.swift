import Foundation
import MurmurSessionCore
import Observation
import Speech

enum TranscriptionLanguageOption: String, CaseIterable, Codable, Sendable, Hashable {
    case systemDefault
    case english
    case spanish
    case french

    var displayName: String {
        switch self {
        case .systemDefault: "System default"
        case .english: "English"
        case .spanish: "Spanish"
        case .french: "French"
        }
    }

    var selection: TranscriptionLanguageSelection {
        switch self {
        case .systemDefault: .systemDefault
        case .english: .locale(identifier: "en")
        case .spanish: .locale(identifier: "es")
        case .french: .locale(identifier: "fr")
        }
    }

    var requestedLocale: Locale {
        switch selection {
        case .systemDefault: .current
        case .locale(let identifier): Locale(identifier: identifier)
        }
    }

    var cleanupProfile: CleanupProfile {
        switch self {
        case .systemDefault: CleanupProfile.forLocale(.current)
        case .english: .english
        case .spanish: .spanish
        case .french: .french
        }
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
