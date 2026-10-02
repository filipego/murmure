import AVFoundation
import CoreAudio
import Testing
@testable import MurmurYouTube

@Suite("Serialized audio capture")
struct SerializedAudioCaptureTests {
    @Test("release stays responsive while start blocks and cancels that start")
    @MainActor
    func releaseDuringBlockedStart() async throws {
        let backend = DelayedAudioCaptureBackend()
        let capture = SerializedAudioCapture(backend: backend)
        let operationID = UUID()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            backend.releaseStarts(1)
        }
        let startTime = Date()
        let startTask = Task { @MainActor in
            try await capture.start(
                operationID: operationID,
                deviceID: 7,
                outputFormat: testAudioFormat,
                onBuffer: { _ in },
                onLevel: { _ in },
                onDeviceChange: { }
            )
        }

        #expect(await backend.waitForStarts(1))
        var releaseWasHandled = false
        var startWasStillBlocked = false
        await Task { @MainActor in
            capture.stop(operationID: operationID)
            releaseWasHandled = true
            startWasStillBlocked = !backend.hasStartFinished
        }.value
        #expect(releaseWasHandled)
        #expect(startWasStillBlocked)
        #expect(Date().timeIntervalSince(startTime) < 0.5)

        backend.releaseStarts(1)
        do {
            try await startTask.value
            Issue.record("Cancelled capture start unexpectedly succeeded.")
        } catch is CancellationError {
            // Expected: release cancelled the in-flight startup.
        }
        await capture.synchronize()
        #expect(backend.events == ["start-1", "start-finished-1", "stop"])
    }

    @Test("a stale stop cannot stop the next recording")
    @MainActor
    func staleStopCannotStopNextStart() async throws {
        let backend = DelayedAudioCaptureBackend()
        let capture = SerializedAudioCapture(backend: backend)
        let firstID = UUID()
        let secondID = UUID()
        let firstStart = Task { @MainActor in
            try await capture.start(
                operationID: firstID,
                deviceID: 7,
                outputFormat: testAudioFormat,
                onBuffer: { _ in },
                onLevel: { _ in },
                onDeviceChange: { }
            )
        }
        #expect(await backend.waitForStarts(1))
        capture.stop(operationID: firstID)
        let secondStart = Task { @MainActor in
            try await capture.start(
                operationID: secondID,
                deviceID: 7,
                outputFormat: testAudioFormat,
                onBuffer: { _ in },
                onLevel: { _ in },
                onDeviceChange: { }
            )
        }
        backend.releaseStarts(1)
        #expect(await backend.waitForStarts(2))
        backend.releaseStarts(2)

        do {
            try await firstStart.value
            Issue.record("Cancelled capture start unexpectedly succeeded.")
        } catch is CancellationError {
        }
        try await secondStart.value
        capture.stop(operationID: firstID)
        await capture.synchronize()
        #expect(backend.events == ["start-1", "start-finished-1", "stop", "start-2", "start-finished-2"])

        capture.stop(operationID: secondID)
        await capture.synchronize()
        #expect(backend.events.last == "stop")
    }
}

private let testAudioFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
)!

private final class DelayedAudioCaptureBackend: AudioCaptureBackend, @unchecked Sendable {
    private let condition = NSCondition()
    private var startCount = 0
    private var releasedCount = 0
    private var recordedEvents: [String] = []

    var events: [String] {
        condition.lock()
        defer { condition.unlock() }
        return recordedEvents
    }

    var hasStartFinished: Bool {
        condition.lock()
        defer { condition.unlock() }
        return recordedEvents.contains("start-finished-1")
    }

    func start(
        deviceID: AudioDeviceID,
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onDeviceChange: @escaping @Sendable () -> Void
    ) throws {
        condition.lock()
        startCount += 1
        let sequence = startCount
        recordedEvents.append("start-\(sequence)")
        condition.broadcast()
        while releasedCount < sequence {
            condition.wait()
        }
        recordedEvents.append("start-finished-\(sequence)")
        condition.broadcast()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        recordedEvents.append("stop")
        condition.broadcast()
        condition.unlock()
    }

    func waitForStarts(_ count: Int) async -> Bool {
        await Task.detached { [self] in waitForStartsBlocking(count) }.value
    }

    private func waitForStartsBlocking(_ count: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 3)
        while startCount < count {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func releaseStarts(_ count: Int) {
        condition.lock()
        releasedCount = max(releasedCount, count)
        condition.broadcast()
        condition.unlock()
    }
}
