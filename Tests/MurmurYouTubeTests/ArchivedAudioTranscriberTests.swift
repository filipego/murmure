import AVFoundation
import MurmurAudioCore
import XCTest
@testable import MurmurYouTube

final class ArchivedAudioTranscriberTests: XCTestCase {
    func testFeedsArchivedChunksInOrderAndReturnsLatestFinalText() async throws {
        let url = try makeArchive(frameCount: 9_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = RecordingArchiveEngine(mode: .success)

        let result = try await ArchivedAudioTranscriber.transcribe(url: url, engine: engine)

        XCTAssertEqual(result.text, "Final archived transcript")
        XCTAssertGreaterThanOrEqual(result.processSeconds, 0)
        let markers = await engine.markers
        XCTAssertEqual(markers.count, 3)
        XCTAssertLessThan(markers[0], markers[1])
        XCTAssertLessThan(markers[1], markers[2])
        let finishCount = await engine.finishCount
        XCTAssertEqual(finishCount, 1)
    }

    func testStreamFailureIsPropagatedAfterFinishingExactlyOnce() async throws {
        let url = try makeArchive(frameCount: 2_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = RecordingArchiveEngine(mode: .streamFailure)

        do {
            _ = try await ArchivedAudioTranscriber.transcribe(url: url, engine: engine)
            XCTFail("Expected the result stream to fail")
        } catch let error as ArchiveEngineTestError {
            XCTAssertEqual(error, .streamFailed)
        }
        let finishCount = await engine.finishCount
        XCTAssertEqual(finishCount, 1)
    }

    func testStartFailureStillFinishesTheEngineExactlyOnce() async throws {
        let url = try makeArchive(frameCount: 2_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = RecordingArchiveEngine(mode: .startFailure)

        do {
            _ = try await ArchivedAudioTranscriber.transcribe(url: url, engine: engine)
            XCTFail("Expected start to fail")
        } catch let error as ArchiveEngineTestError {
            XCTAssertEqual(error, .startFailed)
        }
        let finishCount = await engine.finishCount
        XCTAssertEqual(finishCount, 1)
    }

    func testBlankFinalTranscriptIsRetryableFailure() async throws {
        let url = try makeArchive(frameCount: 2_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = RecordingArchiveEngine(mode: .blank)

        do {
            _ = try await ArchivedAudioTranscriber.transcribe(url: url, engine: engine)
            XCTFail("Expected blank transcript to fail")
        } catch let error as ArchivedAudioTranscriptionError {
            XCTAssertEqual(error, .blankTranscript)
        }
        let finishCount = await engine.finishCount
        XCTAssertEqual(finishCount, 1)
    }

    private func makeArchive(frameCount: AVAudioFrameCount) throws -> URL {
        let format = try AudioArchiveWriter.archiveFormat()
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        for index in 0..<Int(frameCount) {
            samples[index] = Int16(index % Int(Int16.max))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmure-transcriber-\(UUID().uuidString).caf")
        try AudioArchiveWriter.write([buffer], to: url)
        return url
    }
}

private enum ArchiveEngineTestError: Error, Equatable {
    case startFailed
    case streamFailed
}

private actor RecordingArchiveEngine: TranscriptionEngine {
    enum Mode: Sendable {
        case success
        case startFailure
        case streamFailure
        case blank
    }

    private let mode: Mode
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?
    private(set) var markers: [Float] = []
    private(set) var finishCount = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        if mode == .startFailure { throw ArchiveEngineTestError.startFailed }
        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        if let marker = chunk.buffer.floatChannelData?[0][0] {
            markers.append(marker)
        }
    }

    func finish() async {
        finishCount += 1
        switch mode {
        case .success:
            continuation?.yield(TranscriptionChunk(text: "Draft archived", isFinal: false))
            continuation?.yield(TranscriptionChunk(text: "  Final archived transcript  ", isFinal: true))
            continuation?.finish()
        case .streamFailure:
            continuation?.finish(throwing: ArchiveEngineTestError.streamFailed)
        case .blank:
            continuation?.yield(TranscriptionChunk(text: "   ", isFinal: true))
            continuation?.finish()
        case .startFailure:
            break
        }
        continuation = nil
    }
}
