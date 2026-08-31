import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum AudioCaptureError: LocalizedError {
    case inputUnitUnavailable
    case deviceConfigurationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .inputUnitUnavailable:
            "The selected microphone could not be opened."
        case let .deviceConfigurationFailed(status):
            "The selected microphone could not be configured (CoreAudio \(status))."
        }
    }
}

enum AudioConfigurationChangePolicy {
    enum Action: Equatable {
        case ignore
        case restart
        case fail
    }

    static func action(
        selectedDeviceID: AudioDeviceID,
        currentDeviceID: AudioDeviceID,
        isAlive: Bool,
        engineIsRunning: Bool
    ) -> Action {
        guard selectedDeviceID == currentDeviceID, isAlive else { return .fail }
        return engineIsRunning ? .ignore : .restart
    }
}

/// Microphone capture with on-the-fly conversion to whatever format the speech engine wants.
///
/// The tap runs on a real-time audio thread, so everything it touches lives behind
/// `nonisolated(unsafe)` and is only ever mutated from that one thread.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    private var isRunning = false
    private var hasInputTap = false
    private var configurationObserver: NSObjectProtocol?

    /// Called on the audio thread with each converted buffer.
    private nonisolated(unsafe) var onBuffer: (@Sendable (AudioChunk) -> Void)?
    /// Called on the audio thread with a 0…1 RMS level, for the HUD waveform.
    private nonisolated(unsafe) var onLevel: (@Sendable (Float) -> Void)?

    func start(
        deviceID: AudioDeviceID,
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onDeviceChange: @escaping @Sendable () -> Void
    ) throws {
        guard !isRunning else { return }

        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.outputFormat = outputFormat

        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else {
            cleanup()
            throw AudioCaptureError.inputUnitUnavailable
        }
        var selectedDeviceID = deviceID
        let deviceStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard deviceStatus == noErr else {
            cleanup()
            throw AudioCaptureError.deviceConfigurationFailed(deviceStatus)
        }
        let nativeFormat = input.outputFormat(forBus: 0)

        converter = nativeFormat == outputFormat
            ? nil
            : AVAudioConverter(from: nativeFormat, to: outputFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: nativeFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        hasInputTap = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            cleanup()
            throw error
        }
        isRunning = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            if self.recoverConfigurationChange(for: deviceID) { return }
            onDeviceChange()
        }
        Log.audio.info("capture started — native \(nativeFormat.sampleRate)Hz → engine \(outputFormat.sampleRate)Hz")
    }

    func stop() {
        guard isRunning || hasInputTap || configurationObserver != nil else { return }
        cleanup()
        Log.audio.info("capture stopped")
    }

    private func cleanup() {
        if hasInputTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        engine.stop()
        isRunning = false
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        converter = nil
        outputFormat = nil
        onBuffer = nil
        onLevel = nil
    }

    /// AVAudioEngine emits configuration-change notifications for benign format updates as
    /// well as real unplug events (Bluetooth inputs do this immediately after opening). Keep
    /// the session when the same device is alive, restarting the engine if CoreAudio paused it.
    private func recoverConfigurationChange(for selectedDeviceID: AudioDeviceID) -> Bool {
        guard let audioUnit = engine.inputNode.audioUnit else { return false }

        var currentDeviceID = AudioDeviceID(kAudioObjectUnknown)
        var currentSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &currentDeviceID,
            &currentSize
        ) == noErr,
        currentDeviceID == selectedDeviceID else {
            return false
        }

        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var aliveSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            selectedDeviceID,
            &aliveAddress,
            0,
            nil,
            &aliveSize,
            &isAlive
        ) == noErr else {
            return false
        }

        switch AudioConfigurationChangePolicy.action(
            selectedDeviceID: selectedDeviceID,
            currentDeviceID: currentDeviceID,
            isAlive: isAlive != 0,
            engineIsRunning: engine.isRunning
        ) {
        case .ignore:
            return true
        case .fail:
            return false
        case .restart:
            do {
                engine.prepare()
                try engine.start()
                Log.audio.info("capture recovered after a benign configuration change")
                return true
            } catch {
                Log.audio.error("capture recovery failed: \(error.localizedDescription)")
                return false
            }
        }
    }

    // MARK: - Audio thread

    private func handle(_ buffer: AVAudioPCMBuffer) {
        onLevel?(Self.rms(of: buffer))

        guard let outputFormat else { return }

        // AVAudioEngine reuses the tap's buffer as soon as this returns, so the engine
        // must never see it directly — copy when no conversion would otherwise allocate.
        guard let converter else {
            if let copy = Self.copy(buffer) {
                onBuffer?(AudioChunk(buffer: copy))
            }
            return
        }

        // Output frame count scales with the sample-rate ratio; round up so we never clip.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // The input block runs synchronously inside `convert`, on this thread.
        nonisolated(unsafe) let input = buffer
        let consumed = Latch()
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            guard !consumed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }

        if let error {
            Log.audio.error("conversion failed: \(error.localizedDescription)")
            return
        }
        guard status != .error, converted.frameLength > 0 else { return }
        onBuffer?(AudioChunk(buffer: converted))
    }

    /// Deep-copies a tap buffer into storage we own.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }

        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else {
            return nil
        }

        return copy
    }

    /// One-shot flag. Only touched from the audio thread inside a synchronous call.
    private final class Latch: @unchecked Sendable {
        private var fired = false
        /// - Returns: the value *before* this call, then latches to `true`.
        func take() -> Bool {
            defer { fired = true }
            return fired
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()

        // Map roughly -50…0 dBFS onto 0…1 so quiet speech still moves the meter.
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }
}
