import AVFoundation
import XCTest
@testable import MurmurAudioCore

final class AudioArchiveCoreTests: XCTestCase {
    func testArchiveUsesOneExplicitProcessingFormatForMixedInputBuffers() throws {
        let int16 = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let floatStereo = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let first = try Self.buffer(format: int16, frames: 1_600)
        let second = try Self.buffer(format: floatStereo, frames: 4_800)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmure-audio-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        try AudioArchiveWriter.write([first, second], to: url)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, 3_200)
    }

    private static func buffer(format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frames) {
                    channels[channel][frame] = Float((frame + channel) % 100) / 100
                }
            }
        } else if let channels = buffer.int16ChannelData {
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frames) {
                    channels[channel][frame] = Int16((frame + channel) % 100)
                }
            }
        }
        return buffer
    }
}
