import AVFoundation
import XCTest
@testable import MurmurAudioCore

final class AudioArchiveReaderTests: XCTestCase {
    func testReadsCAFInBoundedOrderedChunksAndConvertsFormat() throws {
        let sourceFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let outputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 2_500))
        source.frameLength = 2_500
        let samples = try XCTUnwrap(source.int16ChannelData?[0])
        for index in 0..<2_500 {
            samples[index] = Int16(index - 1_250)
        }

        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioArchiveWriter.write([source], to: url)

        let chunks = try AudioArchiveReader.read(
            from: url,
            convertingTo: outputFormat,
            framesPerChunk: 1_024
        )

        XCTAssertEqual(chunks.map(\.frameLength), [1_024, 1_024, 452])
        XCTAssertTrue(chunks.allSatisfy { $0.frameLength <= 1_024 })
        XCTAssertTrue(chunks.allSatisfy { $0.format.commonFormat == .pcmFormatFloat32 })
        XCTAssertEqual(chunks.reduce(0) { $0 + Int($1.frameLength) }, 2_500)

        let first = try XCTUnwrap(chunks.first?.floatChannelData?[0][0])
        let lastChunk = try XCTUnwrap(chunks.last)
        let last = try XCTUnwrap(lastChunk.floatChannelData?[0][Int(lastChunk.frameLength) - 1])
        XCTAssertEqual(first, Float(-1_250) / 32_768, accuracy: 0.000_001)
        XCTAssertEqual(last, Float(1_249) / 32_768, accuracy: 0.000_001)
    }

    func testEmptyCAFReportsNoAudio() throws {
        let format = try AudioArchiveWriter.archiveFormat()
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        XCTAssertThrowsError(try AudioArchiveReader.read(from: url, convertingTo: format)) { error in
            guard case AudioArchiveError.noAudio = error else {
                return XCTFail("Expected noAudio, received \(error)")
            }
        }
    }

    func testMissingCAFPropagatesAReadError() throws {
        let format = try AudioArchiveWriter.archiveFormat()
        let url = temporaryURL()

        XCTAssertThrowsError(try AudioArchiveReader.read(from: url, convertingTo: format))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("murmure-reader-\(UUID().uuidString).caf")
    }
}
