import AVFoundation
import CoreAudio
import Foundation

protocol AudioCaptureBackend: Sendable {
    func start(
        deviceID: AudioDeviceID,
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onDeviceChange: @escaping @Sendable () -> Void
    ) throws

    func stop()
}

/// Runs all capture lifecycle and configuration recovery work away from the main actor.
/// Operation IDs prevent a queued cancellation from stopping a later dictation.
final class SerializedAudioCapture: @unchecked Sendable {
    private let queue: DispatchQueue
    private let backend: any AudioCaptureBackend
    private let lock = NSLock()
    private var pendingOperations: Set<UUID> = []
    private var cancelledOperations: Set<UUID> = []
    private var activeOperationID: UUID?

    init(backend: (any AudioCaptureBackend)? = nil) {
        let queue = DispatchQueue(label: "ai.pivotstudio.murmur.audio-capture")
        self.queue = queue
        if let backend {
            self.backend = backend
        } else {
            let observerQueue = OperationQueue()
            observerQueue.name = "ai.pivotstudio.murmur.audio-capture-observer"
            observerQueue.maxConcurrentOperationCount = 1
            observerQueue.underlyingQueue = queue
            self.backend = AudioCapture(configurationObserverQueue: observerQueue)
        }
    }

    func start(
        operationID: UUID,
        deviceID: AudioDeviceID,
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onDeviceChange: @escaping @Sendable () -> Void
    ) async throws {
        _ = withLock { pendingOperations.insert(operationID) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { [self] in
                    guard !isCancelled(operationID) else {
                        clearPendingOperation(operationID)
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    do {
                        try backend.start(
                            deviceID: deviceID,
                            outputFormat: outputFormat,
                            onBuffer: onBuffer,
                            onLevel: onLevel,
                            onDeviceChange: onDeviceChange
                        )
                    } catch {
                        clearPendingOperation(operationID)
                        continuation.resume(throwing: error)
                        return
                    }

                    let wasCancelled = withLock {
                        pendingOperations.remove(operationID)
                        if cancelledOperations.remove(operationID) != nil { return true }
                        activeOperationID = operationID
                        return false
                    }
                    if wasCancelled {
                        backend.stop()
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            stop(operationID: operationID)
        }
    }

    /// Schedules stop on the capture queue and returns immediately to the caller.
    func stop(operationID: UUID) {
        withLock {
            if pendingOperations.contains(operationID) || activeOperationID == operationID {
                cancelledOperations.insert(operationID)
            }
        }
        queue.async { [self] in
            let shouldStop = withLock {
                guard activeOperationID == operationID else {
                    if !pendingOperations.contains(operationID) {
                        cancelledOperations.remove(operationID)
                    }
                    return false
                }
                return true
            }
            guard shouldStop else { return }
            backend.stop()
            withLock {
                if activeOperationID == operationID { activeOperationID = nil }
                cancelledOperations.remove(operationID)
            }
        }
    }

    /// A queue barrier for deterministic lifecycle tests.
    func synchronize() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func isCancelled(_ operationID: UUID) -> Bool {
        withLock { cancelledOperations.contains(operationID) }
    }

    private func clearPendingOperation(_ operationID: UUID) {
        withLock {
            pendingOperations.remove(operationID)
            cancelledOperations.remove(operationID)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
