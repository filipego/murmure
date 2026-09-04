import Foundation

struct SnippetEntry: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    var trigger: String
    var replacement: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        trigger: String,
        replacement: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.trigger = trigger.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.replacement = replacement.precomposedStringWithCanonicalMapping
        self.isEnabled = isEnabled
    }
}

struct AppliedSnippet: Codable, Sendable, Equatable {
    let id: UUID
    let trigger: String
}

enum SnippetValidationIssue: Equatable, Sendable {
    case emptyTrigger
    case emptyReplacement
    case duplicateTrigger
    case persistenceFailed

    var message: String {
        switch self {
        case .emptyTrigger: "Say-phrase cannot be empty."
        case .emptyReplacement: "Replacement cannot be empty."
        case .duplicateTrigger: "A snippet already uses that say-phrase."
        case .persistenceFailed: "The snippet could not be saved. Check that your data drive is available."
        }
    }
}

enum SnippetValidator {
    static func validate(
        trigger: String,
        replacement: String,
        entries: [SnippetEntry],
        excludingID: UUID? = nil
    ) -> SnippetValidationIssue? {
        guard !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .emptyTrigger
        }
        guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .emptyReplacement
        }
        let candidate = comparisonKey(trigger)
        if entries.contains(where: { $0.id != excludingID && comparisonKey($0.trigger) == candidate }) {
            return .duplicateTrigger
        }
        return nil
    }

    static func comparisonKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct SnippetExpansionResult: Equatable, Sendable {
    let text: String
    let applied: AppliedSnippet?
}

struct SnippetExpander: Sendable {
    let entries: [SnippetEntry]

    func expand(_ text: String) -> SnippetExpansionResult {
        let key = Self.utteranceKey(text)
        guard let entry = entries.first(where: {
            $0.isEnabled && Self.utteranceKey($0.trigger) == key
        }) else {
            return SnippetExpansionResult(
                text: text.precomposedStringWithCanonicalMapping,
                applied: nil
            )
        }
        return SnippetExpansionResult(
            text: entry.replacement.precomposedStringWithCanonicalMapping,
            applied: AppliedSnippet(id: entry.id, trigger: entry.trigger)
        )
    }

    private static func utteranceKey(_ value: String) -> String {
        let normalized = commandBody(value).precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        return SnippetValidator.comparisonKey(normalized)
    }

    private static func commandBody(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = normalized.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )

        for prefix in ["murmure add", "murmur add"] where folded.hasPrefix(prefix) {
            let suffix = normalized.dropFirst(prefix.count)
            guard suffix.first.map({ $0.isWhitespace || $0.isPunctuation }) == true else {
                continue
            }
            return String(suffix)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        return normalized
    }
}
