import AppKit
import Foundation
import Observation

@MainActor
protocol HistoryAudioPlayback: AnyObject {
    func play(
        url: URL,
        onFinish: @escaping @MainActor @Sendable () -> Void
    ) -> Bool
    func stop()
}

@MainActor
@Observable
final class HistoryAudioPlayer {
    enum State: Equatable {
        case idle
        case playing(UUID)
        case error(UUID, String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored
    private let playback: any HistoryAudioPlayback

    init(playback: any HistoryAudioPlayback = NSSoundHistoryPlayback()) {
        self.playback = playback
    }

    func toggle(id: UUID, url: URL) {
        if state == .playing(id) {
            stop()
            return
        }

        if case .playing = state {
            playback.stop()
        }
        let started = playback.play(url: url) { [weak self] in
            guard let self, self.state == .playing(id) else { return }
            self.state = .idle
        }
        state = started
            ? .playing(id)
            : .error(id, "The saved recording could not be played.")
    }

    func stop() {
        playback.stop()
        state = .idle
    }
}

@MainActor
private final class NSSoundHistoryPlayback: NSObject, HistoryAudioPlayback, NSSoundDelegate {
    private var sound: NSSound?
    private var onFinish: (@MainActor @Sendable () -> Void)?

    func play(
        url: URL,
        onFinish: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        stop()
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return false }
        self.sound = sound
        self.onFinish = onFinish
        sound.delegate = self
        guard sound.play() else {
            self.sound = nil
            self.onFinish = nil
            return false
        }
        return true
    }

    func stop() {
        sound?.stop()
        sound?.delegate = nil
        sound = nil
        onFinish = nil
    }

    func sound(_ sound: NSSound, didFinishPlaying finishedPlaying: Bool) {
        guard sound === self.sound else { return }
        let completion = onFinish
        self.sound = nil
        self.onFinish = nil
        completion?()
    }
}
