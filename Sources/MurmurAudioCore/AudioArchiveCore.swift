import AVFoundation
import Foundation

/// Errors that can be reported while normalising a captured recording for local history.
public enum AudioArchiveError: LocalizedError, Sendable {
    case noAudio
    case invalidInputFormat
    case converterUnavailable
    case conversionFailed(String)
    case unsupportedOutputBuffer
    case frameCountOverflow

    public var errorDescription: String? {
        switch self {
        case .noAudio:
            return "The recording did not contain any audio frames."
        case .invalidInputFormat:
            return "The captured audio format was invalid."
        case .converterUnavailable:
            return "The captured audio format could not be converted."
        case .conversionFailed(let detail):
            return "Audio conversion failed: \(detail)"
        case .unsupportedOutputBuffer:
            return "The audio archive buffer could not be allocated."
        case .frameCountOverflow:
            return "The recording is too long to archive as one audio file."
        }
    }
}

/// Writes a recording using one explicit PCM processing format.
///
/// `AVAudioFile(forWriting:settings:)` defaults its *processing* format to Float32 even when
/// the file settings describe Int16 PCM. Passing an Int16 `AVAudioPCMBuffer` to that file can
/// trigger Core Audio's `CAVerboseAbort` instead of throwing. This writer normalises every
/// input buffer to one canonical format and supplies that same format explicitly to the file.
public enum AudioArchiveWriter {
    public static let sampleRate = 16_000.0
    public static let channelCount: AVAudioChannelCount = 1

    /// The compact, lossless-enough format used for local speech history.
    public static func archiveFormat() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            throw AudioArchiveError.unsupportedOutputBuffer
        }
        return format
    }

    /// Converts, concatenates, and writes the non-empty buffers to `url`.
    public static func write(_ buffers: [AVAudioPCMBuffer], to url: URL) throws {
        let inputs = buffers.filter { $0.frameLength > 0 }
        guard !inputs.isEmpty else { throw AudioArchiveError.noAudio }

        let format = try archiveFormat()
        var normalised: [AVAudioPCMBuffer] = []
        normalised.reserveCapacity(inputs.count)

        for input in inputs {
            normalised.append(try convert(input, to: format))
        }

        var totalFrames: UInt64 = 0
        for buffer in normalised {
            totalFrames += UInt64(buffer.frameLength)
        }
        guard totalFrames > 0,
              totalFrames <= UInt64(AVAudioFrameCount.max)
        else {
            throw AudioArchiveError.frameCountOverflow
        }

        let frameCount = AVAudioFrameCount(totalFrames)
        guard let joined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let destination = joined.int16ChannelData?[0]
        else {
            throw AudioArchiveError.unsupportedOutputBuffer
        }

        joined.frameLength = frameCount
        var offset = 0
        for buffer in normalised {
            let count = Int(buffer.frameLength)
            guard let source = buffer.int16ChannelData?[0] else {
                throw AudioArchiveError.unsupportedOutputBuffer
            }
            destination.advanced(by: offset).update(from: source, count: count)
            offset += count
        }

        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: joined)
    }

    private static func convert(_ input: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard input.frameLength > 0,
              input.format.sampleRate > 0,
              input.format.channelCount > 0
        else {
            throw AudioArchiveError.invalidInputFormat
        }

        if isCanonical(input.format, matching: outputFormat) {
            return try copyCanonical(input, format: outputFormat)
        }

        guard let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
            throw AudioArchiveError.converterUnavailable
        }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let estimatedCapacity = (Double(input.frameLength) * ratio).rounded(.up) + 64
        guard estimatedCapacity <= Double(AVAudioFrameCount.max) else {
            throw AudioArchiveError.frameCountOverflow
        }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(estimatedCapacity)
        ) else {
            throw AudioArchiveError.unsupportedOutputBuffer
        }

        // The input block is called synchronously by `convert`; the source buffer is owned by
        // the history session and remains alive until conversion returns.
        nonisolated(unsafe) let source = input
        let supplied = Latch()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, statusPointer in
            guard !supplied.take() else {
                statusPointer.pointee = .endOfStream
                return nil
            }
            statusPointer.pointee = .haveData
            return source
        }

        if let conversionError {
            throw AudioArchiveError.conversionFailed(conversionError.localizedDescription)
        }
        guard status != .error, output.frameLength > 0 else {
            throw AudioArchiveError.conversionFailed("the converter returned no audio frames")
        }
        return output
    }

    private static func isCanonical(_ input: AVAudioFormat, matching output: AVAudioFormat) -> Bool {
        input.commonFormat == output.commonFormat &&
        input.sampleRate == output.sampleRate &&
        input.channelCount == output.channelCount &&
        input.isInterleaved == output.isInterleaved
    }

    private static func copyCanonical(_ input: AVAudioPCMBuffer, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frames = input.frameLength
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let source = input.int16ChannelData?[0],
              let destination = copy.int16ChannelData?[0]
        else {
            throw AudioArchiveError.unsupportedOutputBuffer
        }
        copy.frameLength = frames
        destination.update(from: source, count: Int(frames))
        return copy
    }

    /// One-shot state used only by the synchronous AVAudioConverter input callback.
    private final class Latch: @unchecked Sendable {
        private var fired = false

        func take() -> Bool {
            defer { fired = true }
            return fired
        }
    }
}
