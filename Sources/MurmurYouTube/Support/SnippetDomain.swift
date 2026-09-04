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
    let language: TranscriptionLanguageOption

    init(
        entries: [SnippetEntry],
        language: TranscriptionLanguageOption = .english
    ) {
        self.entries = entries
        self.language = language
    }

    func expand(_ text: String) -> SnippetExpansionResult {
        let normalizedText = text.precomposedStringWithCanonicalMapping
        if let commandBody = deliberateCommandBody(normalizedText),
           let invocation = deliberateInvocation(in: commandBody) {
            return SnippetExpansionResult(
                text: invocation.entry.replacement.precomposedStringWithCanonicalMapping
                    + invocation.trailingText,
                applied: AppliedSnippet(
                    id: invocation.entry.id,
                    trigger: invocation.entry.trigger
                )
            )
        }

        let key = Self.utteranceKey(normalizedText)
        guard let entry = entries.first(where: {
            $0.isEnabled && Self.utteranceKey($0.trigger) == key
        }) else {
            return SnippetExpansionResult(
                text: normalizedText,
                applied: nil
            )
        }
        return SnippetExpansionResult(
            text: entry.replacement.precomposedStringWithCanonicalMapping,
            applied: AppliedSnippet(id: entry.id, trigger: entry.trigger)
        )
    }

    private func deliberateInvocation(
        in body: String
    ) -> (entry: SnippetEntry, trailingText: String)? {
        var best: (entry: SnippetEntry, end: String.Index, triggerLength: Int)?
        let boundaries = body.indices.filter {
            body[$0].isWhitespace || body[$0].isPunctuation
        } + [body.endIndex]

        for end in boundaries {
            let candidateKey = Self.utteranceKey(String(body[..<end]))
            guard !candidateKey.isEmpty,
                  let entry = entries.first(where: {
                      $0.isEnabled && Self.utteranceKey($0.trigger) == candidateKey
                  })
            else { continue }

            let triggerLength = candidateKey.count
            let candidateEnd = body.distance(from: body.startIndex, to: end)
            let shouldReplaceBest = best.map {
                triggerLength > $0.triggerLength
                    || (triggerLength == $0.triggerLength
                        && candidateEnd < body.distance(from: body.startIndex, to: $0.end))
            } ?? true
            if shouldReplaceBest {
                best = (entry, end, triggerLength)
            }
        }

        guard let best else { return nil }
        let trailingText = String(body[best.end...])
        let preservesTrailingText = trailingText.contains {
            !$0.isWhitespace && !$0.isPunctuation
        }
        return (best.entry, preservesTrailingText ? trailingText : "")
    }

    private static func utteranceKey(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        return SnippetValidator.comparisonKey(normalized)
    }

    private func deliberateCommandBody(_ value: String) -> String? {
        let normalized = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = SnippetCommandLexicon.comparisonKey(normalized)

        for command in SnippetCommandLexicon.commands(for: language) {
            let prefix = SnippetCommandLexicon.comparisonKey(command)
            guard folded.hasPrefix(prefix) else { continue }
            let suffix = normalized.dropFirst(command.count)
            guard suffix.first.map({ $0.isWhitespace || $0.isPunctuation }) == true else {
                continue
            }
            return String(suffix).drop(while: {
                $0.isWhitespace || $0.isPunctuation
            }).description
        }
        return nil
    }
}
