import AVFoundation
import Foundation

/// Reads an archived dictation without loading the whole recording into one allocation.
///
/// The caller chooses the processing format so the returned buffers can be fed directly to
/// one speech engine. Every returned buffer is newly allocated and safe to retain after the
/// file advances to its next chunk.
public enum AudioArchiveReader {
    public static func read(
        from url: URL,
        convertingTo outputFormat: AVAudioFormat,
        framesPerChunk: AVAudioFrameCount = 4_096
    ) throws -> [AVAudioPCMBuffer] {
        guard framesPerChunk > 0,
              outputFormat.sampleRate > 0,
              outputFormat.channelCount > 0
        else {
            throw AudioArchiveError.invalidInputFormat
        }

        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioArchiveError.invalidInputFormat
        }

        var chunks: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let requested = AVAudioFrameCount(min(AVAudioFramePosition(framesPerChunk), remaining))
            guard requested > 0,
                  let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: requested)
            else {
                throw AudioArchiveError.unsupportedOutputBuffer
            }

            try file.read(into: input, frameCount: requested)
            guard input.frameLength > 0 else { break }
            chunks.append(try convert(input, to: outputFormat))
        }

        guard chunks.contains(where: { $0.frameLength > 0 }) else {
            throw AudioArchiveError.noAudio
        }
        return chunks
    }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        if formatsMatch(input.format, outputFormat) {
            return input
        }

        guard let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
            throw AudioArchiveError.converterUnavailable
        }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let estimatedCapacity = (Double(input.frameLength) * ratio).rounded(.up) + 64
        guard estimatedCapacity <= Double(AVAudioFrameCount.max),
              let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(estimatedCapacity)
              )
        else {
            throw AudioArchiveError.frameCountOverflow
        }

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

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private final class Latch: @unchecked Sendable {
        private var fired = false

        func take() -> Bool {
            defer { fired = true }
            return fired
        }
    }
}
