import Foundation
import MurmurAudioCore

struct ArchivedTranscription: Equatable, Sendable {
    let text: String
    let processSeconds: Double
}

enum ArchivedAudioTranscriptionError: LocalizedError, Equatable, Sendable {
    case noAudioFormat
    case blankTranscript

    var errorDescription: String? {
        switch self {
        case .noAudioFormat:
            "The selected speech engine could not accept this recording."
        case .blankTranscript:
            "No words were recognized in the saved recording."
        }
    }
}

/// Runs archived audio through one local engine without formatting, persistence, or insertion.
enum ArchivedAudioTranscriber {
    static func transcribe(
        url: URL,
        engine: any TranscriptionEngine
    ) async throws -> ArchivedTranscription {
        guard let format = await engine.preferredInputFormat() else {
            throw ArchivedAudioTranscriptionError.noAudioFormat
        }
        let buffers = try AudioArchiveReader.read(from: url, convertingTo: format)
        let chunks = buffers.map(AudioChunk.init(buffer:))

        var finished = false
        do {
            let stream = try await engine.start()
            let started = Date()
            let collector = Task { () throws -> String in
                var latest = ""
                for try await chunk in stream {
                    latest = chunk.text
                }
                return latest
            }

            for chunk in chunks {
                await engine.feed(chunk)
            }
            await engine.finish()
            finished = true

            let text = try await collector.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw ArchivedAudioTranscriptionError.blankTranscript
            }
            return ArchivedTranscription(
                text: text,
                processSeconds: Date().timeIntervalSince(started)
            )
        } catch {
            if !finished {
                await engine.finish()
            }
            throw error
        }
    }
}
