import Foundation

public enum SessionEngineID: String, Codable, Sendable, Equatable {
    case apple
    case parakeet
}

public enum TranscriptionLanguageSelection: Codable, Sendable, Equatable {
    case systemDefault
    case locale(identifier: String)
}

public enum RecordingTrigger: Codable, Sendable, Equatable {
    case holdToTalk(bindingID: String)
    case handsFree(bindingID: String)
    case mainButton
    case retry(sourceRunID: UUID)
}

public struct RecordingFailure: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable, Equatable {
        case audioStaging
        case transcription
        case formatting
        case historyPersistence
        case audioPromotion
        case insertion
    }

    public let stage: Stage
    public let message: String

    public init(stage: Stage, message: String) {
        self.stage = stage
        self.message = message
    }
}

public enum RecordingSessionStatus: Codable, Sendable, Equatable {
    case recording
    case readyForTranscription
    case processing
    case processed(finalText: String)
    case failed(RecordingFailure)
    case completed(runID: UUID)
    case cancelled

    public var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

public enum RecordingSessionTransitionError: Error, Sendable, Equatable {
    case invalidTransition
    case emptyAudioFile
    case emptyFinalText
}

public struct RecordingSessionManifest: Codable, Sendable, Identifiable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let startedAt: Date
    public var releasedAt: Date?
    public let trigger: RecordingTrigger
    public let engine: SessionEngineID
    public let language: TranscriptionLanguageSelection
    public var audioFile: String?
    public private(set) var status: RecordingSessionStatus

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        startedAt: Date = Date(),
        trigger: RecordingTrigger,
        engine: SessionEngineID,
        language: TranscriptionLanguageSelection,
        releasedAt: Date? = nil,
        audioFile: String? = nil,
        status: RecordingSessionStatus = .recording
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.startedAt = startedAt
        self.releasedAt = releasedAt
        self.trigger = trigger
        self.engine = engine
        self.language = language
        self.audioFile = audioFile
        self.status = status
    }

    public mutating func release(at date: Date, audioFile: String) throws {
        guard !audioFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecordingSessionTransitionError.emptyAudioFile
        }
        guard Self.permits(status, .readyForTranscription) else {
            throw RecordingSessionTransitionError.invalidTransition
        }
        releasedAt = date
        self.audioFile = audioFile
        status = .readyForTranscription
    }

    public mutating func transition(to next: RecordingSessionStatus) throws {
        if case let .processed(finalText) = next,
           finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RecordingSessionTransitionError.emptyFinalText
        }
        guard Self.permits(status, next) else {
            throw RecordingSessionTransitionError.invalidTransition
        }
        status = next
    }

    private static func permits(
        _ current: RecordingSessionStatus,
        _ next: RecordingSessionStatus
    ) -> Bool {
        switch (current, next) {
        case (.recording, .readyForTranscription),
             (.recording, .failed),
             (.recording, .cancelled),
             (.readyForTranscription, .processing),
             (.readyForTranscription, .failed),
             (.processing, .processed),
             (.processing, .failed),
             (.processed, .completed),
             (.processed, .failed),
             (.failed, .processing),
             (.failed, .cancelled):
            true
        default:
            false
        }
    }
}

public extension JSONEncoder {
    static var sessionEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var sessionDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
