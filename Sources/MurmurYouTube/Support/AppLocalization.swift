import Foundation
import Observation
import SwiftUI

enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case french = "fr"
    case spanish = "es"

    var nativeName: String {
        switch self {
        case .english: "English"
        case .french: "Français"
        case .spanish: "Español"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    static func preferred(from identifiers: [String]) -> AppLanguage {
        for identifier in identifiers {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
            if let language = AppLanguage(rawValue: code ?? "") { return language }
        }
        return .english
    }
}

@MainActor
@Observable
final class AppLanguageStore {
    static let shared = AppLanguageStore()
    nonisolated static let defaultKey = "appLanguage"

    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: key) }
    }

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = AppLanguageStore.defaultKey,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.defaults = defaults
        self.key = key
        language = AppLanguage(rawValue: defaults.string(forKey: key) ?? "")
            ?? AppLanguage.preferred(from: preferredLanguages)
    }
}

struct AppLanguageRoot<Content: View>: View {
    @State private var appLanguage = AppLanguageStore.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.environment(\.locale, appLanguage.language.locale)
    }
}

enum L10n {
    static func text(_ key: String, language: AppLanguage? = nil) -> String {
        let selected = language ?? currentLanguage
        guard selected != .english else { return key }
        return catalog.rows[key]?[selected] ?? key
    }

    static func format(
        _ key: String,
        language: AppLanguage? = nil,
        arguments: [CVarArg]
    ) -> String {
        let selected = language ?? currentLanguage
        return String(
            format: text(key, language: selected),
            locale: selected.locale,
            arguments: arguments
        )
    }

    static func catalogIssues() throws -> [String] {
        var issues = catalog.issues
        for (key, values) in catalog.rows.sorted(by: { $0.key < $1.key }) {
            for language in [AppLanguage.french, .spanish] {
                guard let value = values[language], !value.isEmpty else {
                    issues.append("\(language.rawValue) missing: \(key)")
                    continue
                }
                guard placeholders(in: key) == placeholders(in: value) else {
                issues.append("\(language.rawValue) placeholders differ: \(key)")
                    continue
                }
            }
        }
        return issues
    }

    private static var currentLanguage: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(
            forKey: AppLanguageStore.defaultKey
        ) ?? "") ?? AppLanguage.preferred(from: Locale.preferredLanguages)
    }

    private struct Catalog {
        var rows: [String: [AppLanguage: String]] = [:]
        var issues: [String] = []
    }

    private static let catalog: Catalog = {
        let url = Bundle.main.url(forResource: "catalog", withExtension: "tsv")
            ?? Bundle.module.url(forResource: "catalog", withExtension: "tsv")
        guard let url,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return Catalog(issues: ["catalog.tsv is unavailable"])
        }
        var result = Catalog()
        for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index == 0 || line.isEmpty { continue }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count == 3 else {
                result.issues.append("line \(index + 1) has \(columns.count) columns")
                continue
            }
            let key = columns[0]
            guard result.rows[key] == nil else {
                result.issues.append("duplicate key: \(key)")
                continue
            }
            result.rows[key] = [.french: columns[1], .spanish: columns[2]]
        }
        return result
    }()

    private static func placeholders(in value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:@|d|ld|lld|f|\.\d+f)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }
}
