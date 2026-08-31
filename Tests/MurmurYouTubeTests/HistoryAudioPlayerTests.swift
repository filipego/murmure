import Foundation
import Testing
@testable import MurmurYouTube

@Suite("History audio player")
@MainActor
struct HistoryAudioPlayerTests {
    @Test("toggle starts and stops the same recording")
    func togglesSameRecording() {
        let adapter = RecordingPlaybackAdapter()
        let player = HistoryAudioPlayer(playback: adapter)
        let id = UUID()
        let url = URL(fileURLWithPath: "/tmp/one.caf")

        player.toggle(id: id, url: url)
        #expect(player.state == .playing(id))
        #expect(adapter.events == [.play(url)])

        player.toggle(id: id, url: url)
        #expect(player.state == .idle)
        #expect(adapter.events == [.play(url), .stop])
    }

    @Test("starting another recording stops the first")
    func switchesRecording() {
        let adapter = RecordingPlaybackAdapter()
        let player = HistoryAudioPlayer(playback: adapter)
        let first = URL(fileURLWithPath: "/tmp/one.caf")
        let second = URL(fileURLWithPath: "/tmp/two.caf")

        player.toggle(id: UUID(), url: first)
        let secondID = UUID()
        player.toggle(id: secondID, url: second)

        #expect(player.state == .playing(secondID))
        #expect(adapter.events == [.play(first), .stop, .play(second)])
    }

    @Test("failed playback is visible and stop clears state")
    func failedPlaybackAndStop() {
        let adapter = RecordingPlaybackAdapter(shouldPlay: false)
        let player = HistoryAudioPlayer(playback: adapter)
        let id = UUID()
        let url = URL(fileURLWithPath: "/tmp/missing.caf")

        player.toggle(id: id, url: url)
        #expect(player.state == .error(id, "The saved recording could not be played."))

        player.stop()
        #expect(player.state == .idle)
        #expect(adapter.events == [.play(url), .stop])
    }

    @Test("natural playback completion clears the active recording")
    func completionClearsState() {
        let adapter = RecordingPlaybackAdapter()
        let player = HistoryAudioPlayer(playback: adapter)
        let id = UUID()

        player.toggle(id: id, url: URL(fileURLWithPath: "/tmp/one.caf"))
        adapter.complete()

        #expect(player.state == .idle)
    }
}

@MainActor
private final class RecordingPlaybackAdapter: HistoryAudioPlayback {
    enum Event: Equatable {
        case play(URL)
        case stop
    }

    let shouldPlay: Bool
    private(set) var events: [Event] = []
    private var completion: (@MainActor @Sendable () -> Void)?

    init(shouldPlay: Bool = true) {
        self.shouldPlay = shouldPlay
    }

    func play(url: URL, onFinish: @escaping @MainActor @Sendable () -> Void) -> Bool {
        events.append(.play(url))
        completion = onFinish
        return shouldPlay
    }

    func stop() {
        events.append(.stop)
        completion = nil
    }

    func complete() {
        let completion = completion
        self.completion = nil
        completion?()
    }
}
