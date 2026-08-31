import MurmurDictionary
import AVFoundation
import AppKit
import Foundation
import Observation
import MurmurSessionCore

/// Builds the engine named by the current setting.
///
/// Deliberately at file scope rather than a static on `DictationController`: the class is
/// `@MainActor`, which would make a static method main-actor-isolated and therefore
/// ineligible to be `@Sendable`. Reading the setting per-utterance is what lets the menu's
/// engine picker take effect on the very next hold instead of needing a restart.
@Sendable
func engineForCurrentSetting() -> any TranscriptionEngine {
    // Always invoked from `beginDictation`, which runs on the main actor.
    MainActor.assumeIsolated {
        switch Settings.shared.engine {
        case .apple: AppleSpeechEngine()
        case .parakeet: ParakeetEngine()
        }
    }
}

@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case finishing
        case error(String)

        var isActive: Bool {
            switch self {
            case .starting, .listening, .finishing: true
            case .idle, .error: false
            }
        }
    }

    private(set) var state: State = .idle
    /// Live transcript, updated as the engine revises it. Drives the HUD.
    private(set) var transcript = ""
    /// Smoothed 0…1 mic level for the waveform.
    private(set) var level: Float = 0

    private let hotkey = HotkeyMonitor()
    private let capture = AudioCapture()
    private let makeEngine: @Sendable () -> any TranscriptionEngine
    private let sessionCoordinator: RecordingSessionCoordinator
    private var wantsHotkeyActive = false
    private var isHotkeySuspendedForModalInput = false
    private var handsFreePolicy = HandsFreeGesturePolicy()
    private var activeTrigger: RecordingTrigger?

    var canStartButtonRecording: Bool {
        guard !isHotkeySuspendedForModalInput else { return false }
        return state == .idle
    }

    /// Injected only by tests; production reads the setting per-utterance below.
    private let formatter: (any TextFormatter)?

    /// Chosen per-utterance so the menu toggle applies to the very next hold.
    private var activeFormatter: any TextFormatter {
        if let formatter { return formatter }
        return Settings.shared.smartCleanup
            ? FoundationModelFormatter()
            : RuleBasedFormatter()
    }

    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    /// Returns the ordered recording when the session finishes. The same buffers are fed to
    /// the selected engine and retained briefly so Murmure can archive the local audio once
    /// transcription is complete.
    private var feedTask: Task<[AudioChunk], Never>?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?

    /// Timestamps for the dashboard: when the key went down, and when it came up.
    private var holdStarted: Date?
    private var releasedAt: Date?
    private var engineName = ""

    /// The just-finished recording, kept until its CAF archive and comparison pass are done.
    private var recorded: [AudioChunk] = []
    private var isComparing = false
    private var activeSessionID: UUID?

    init(
        formatter: (any TextFormatter)? = nil,
        makeEngine: @escaping @Sendable () -> any TranscriptionEngine = engineForCurrentSetting,
        sessionCoordinator: RecordingSessionCoordinator = RecordingSessionRuntime.coordinator
    ) {
        self.formatter = formatter
        self.makeEngine = makeEngine
        self.sessionCoordinator = sessionCoordinator
    }

    // MARK: - Lifecycle

    /// - Returns: `false` if the hotkey tap couldn't be installed (missing Accessibility).
    @discardableResult
    func activate() -> Bool {
        wantsHotkeyActive = true
        guard !isHotkeySuspendedForModalInput else { return true }
        return armHotkey()
    }

    private func armHotkey() -> Bool {
        hotkey.key = Settings.shared.pushToTalkKey
        hotkey.handsFreeKey = Settings.shared.handsFreeEnabled
            ? Settings.shared.handsFreeKey
            : nil
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            self.beginDictation(
                trigger: .holdToTalk(bindingID: Settings.shared.pushToTalkKey.rawValue)
            )
        }
        hotkey.onRelease = { [weak self] in self?.endHoldToTalkDictation() }
        hotkey.isHandsFreeActive = { [weak self] in
            self?.handsFreePolicy.isActive ?? false
        }
        hotkey.onHandsFreeToggle = { [weak self] in
            self?.handleHandsFree(.bindingPressed)
        }
        hotkey.onHandsFreeFinish = { [weak self] in
            self?.handleHandsFree(.enterPressed)
        }
        hotkey.onHandsFreeCancel = { [weak self] in
            self?.handleHandsFree(.escapePressed)
        }
        return hotkey.start()
    }

    func deactivate() {
        wantsHotkeyActive = false
        hotkey.stop()
        cancelDictation()
    }

    /// Re-arms the tap after the user picks a different push-to-talk key.
    @discardableResult
    func reloadHotkey() -> Bool {
        hotkey.stop()
        wantsHotkeyActive = true
        guard !isHotkeySuspendedForModalInput else { return true }
        return armHotkey()
    }

    func suspendHotkeyForModalInput() {
        guard !isHotkeySuspendedForModalInput else { return }
        isHotkeySuspendedForModalInput = true
        hotkey.stop()
    }

    func resumeHotkeyAfterModalInput() {
        guard isHotkeySuspendedForModalInput else { return }
        isHotkeySuspendedForModalInput = false
        guard wantsHotkeyActive else { return }
        _ = armHotkey()
    }

    // MARK: - Button-driven recording

    /// Starts a recording from a Record button rather than the hotkey.
    func startButtonRecording() {
        guard canStartButtonRecording else { return }
        beginDictation(trigger: .mainButton)
    }

    func stopButtonRecording() {
        endDictation()
    }

    private func endHoldToTalkDictation() {
        guard case .holdToTalk = activeTrigger else { return }
        endDictation()
    }

    private func handleHandsFree(_ event: HandsFreeGesturePolicy.Event) {
        if event == .bindingPressed,
           !handsFreePolicy.isActive,
           state != .idle {
            return
        }

        switch handsFreePolicy.handle(event) {
        case .start:
            beginDictation(
                trigger: .handsFree(bindingID: Settings.shared.handsFreeKey.rawValue)
            )
        case .finish:
            endDictation()
        case .cancel:
            cancelDictation()
        case .ignore:
            break
        }
    }

    // MARK: - Dictation

    private func beginDictation(trigger: RecordingTrigger) {
        guard case .idle = state else { return }
        state = .starting
        activeTrigger = trigger
        transcript = ""
        holdStarted = Date()
        isComparing = Settings.shared.compareMode
        activeSessionID = nil
        recorded.removeAll(keepingCapacity: true)
        engineName = isComparing ? "Comparing…" : Settings.shared.engine.displayName

        Task { @MainActor in
            do {
                guard await Permissions.requestMicrophone() else {
                    fail("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                    return
                }

                if !isComparing {
                    let engineID: SessionEngineID = Settings.shared.engine == .apple ? .apple : .parakeet
                    let session = try await sessionCoordinator.begin(
                        startedAt: holdStarted ?? Date(),
                        trigger: trigger,
                        engine: engineID,
                        language: .systemDefault
                    )
                    activeSessionID = session.id
                }

                let engine = makeEngine()
                self.engine = engine

                let chunks = try await engine.start()

                // Compare mode captures in *Apple's* format, not a format of our choosing.
                //
                // SpeechAnalyzer enforces `Audio sample data must be 16-bit signed integers`
                // as a hard precondition — feeding it float32 doesn't fail gracefully, it
                // kills the process. Parakeet is the flexible one (its `feed` converts
                // int16/int32/float32), so the strict engine picks the format and the
                // tolerant engine adapts. Both still replay the identical buffers.
                let formatOwner: any TranscriptionEngine = isComparing ? AppleSpeechEngine() : engine
                guard let format = await formatOwner.preferredInputFormat() else {
                    throw TranscriptionError.noAudioFormat
                }

                // Audio must reach the engine in capture order. A stream plus a single
                // draining task guarantees that; spawning a Task per buffer would not. Keep
                // the stream unbounded for the short-lived session so a busy transcription
                // engine cannot drop older buffers that the audio archive still needs.
                let (audioStream, audioContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .unbounded
                )
                self.audioContinuation = audioContinuation

                // The recording is accumulated *inside* the ordered drain, not by spawning
                // a task per buffer. Unstructured tasks have no ordering guarantee, so
                // collecting them separately could assemble the replay audio out of order
                // and silently produce word-salad from the comparison.
                self.feedTask = Task.detached(priority: .userInitiated) {
                    var recording: [AudioChunk] = []
                    for await chunk in audioStream {
                        // Keep one ordered copy for local audio history. This is done in the
                        // same serial drain that feeds the engine, so the archive cannot be
                        // assembled out of order.
                        recording.append(chunk)
                        await engine.feed(chunk)
                    }
                    return recording
                }

                try capture.start(
                    outputFormat: format,
                    onBuffer: { chunk in
                        audioContinuation.yield(chunk)
                    },
                    onLevel: { [weak self] level in
                        Task { @MainActor in self?.updateLevel(level) }
                    }
                )

                // Bail out if the user already let go while we were spinning up.
                guard case .starting = self.state else {
                    await self.teardown()
                    return
                }

                self.state = .listening
                if Settings.shared.soundEnabled { NSSound(named: "Tink")?.play() }

                self.consumeTask = Task { @MainActor in
                    do {
                        for try await chunk in chunks {
                            self.transcript = chunk.text
                        }
                    } catch {
                        self.fail(error.localizedDescription)
                    }
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func endDictation() {
        if handsFreePolicy.isActive,
           case .handsFree = activeTrigger {
            _ = handsFreePolicy.handle(.enterPressed)
        }

        // `.finishing` is "active", so without this a second press during processing would
        // run the whole tail again — re-reading `transcript` before the first pass cleared
        // it and pasting the same utterance twice. The window is wide: Parakeet transcribes
        // inside `finish()`, and smart cleanup adds up to 4s on top.
        guard state.isActive, state != .finishing else { return }
        state = .finishing
        capture.stop()
        level = 0
        releasedAt = Date()

        Task { @MainActor in
            // Drain every captured buffer into the engine before asking it to finalize,
            // or the tail of the utterance gets dropped.
            audioContinuation?.finish()
            audioContinuation = nil
            recorded = await feedTask?.value ?? []
            feedTask = nil

            await engine?.finish()
            await consumeTask?.value
            consumeTask = nil
            engine = nil

            if isComparing {
                await runComparison()
                return
            }

            guard let sessionID = activeSessionID, let releasedAt else {
                fail("The recording session could not be recovered.")
                return
            }

            do {
                _ = try await sessionCoordinator.stageReleasedAudio(
                    sessionID: sessionID,
                    chunks: recorded,
                    releasedAt: releasedAt
                )
            } catch {
                activeSessionID = nil
                fail("The recording was retained locally, but audio staging failed: \(error.localizedDescription)")
                return
            }

            let raw = transcript
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                _ = try? await sessionCoordinator.persistProcessedText(
                    sessionID: sessionID,
                    finalText: raw
                )
                activeSessionID = nil
                holdStarted = nil
                self.releasedAt = nil
                resetTriggerLifecycle()
                state = .idle
                transcript = ""
                return
            }

            let cleaned = Settings.shared.cleanupEnabled
                ? await activeFormatter.format(raw)
                : raw

            // The dictionary runs last, and runs regardless of the cleanup setting. Biasing
            // only raises the odds of the right word; this is the pass that guarantees it,
            // so it must not be something the user can accidentally switch off.
            let (output, corrections) = DictionaryStore.shared.corrector.apply(to: cleaned)
            if !corrections.isEmpty {
                Log.speech.info("dictionary · \(corrections.count, privacy: .public) correction(s) applied")
            }

            do {
                _ = try await sessionCoordinator.persistProcessedText(
                    sessionID: sessionID,
                    finalText: output
                )
            } catch {
                fail("The transcript could not be made durable: \(error.localizedDescription)")
                return
            }

            let run = DictationRun(
                id: sessionID,
                date: releasedAt,
                engine: engineName,
                audioSeconds: releasedAt.timeIntervalSince(holdStarted ?? releasedAt),
                processSeconds: Date().timeIntervalSince(releasedAt),
                text: output,
                corrections: corrections.isEmpty ? nil : corrections
            )
            let completed = await sessionCoordinator.completeLiveSession(
                sessionID: sessionID,
                run: run,
                insert: { text in TextInjector.insert(text) }
            )
            activeSessionID = nil
            guard completed else {
                fail("The transcript is safe locally and will be retried from history recovery.")
                return
            }
            if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }

            holdStarted = nil
            self.releasedAt = nil
            resetTriggerLifecycle()
            state = .idle
            transcript = ""
        }
    }

    private func cancelDictation() {
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil

        let engine = self.engine
        self.engine = nil
        Task { await engine?.finish() }

        if let sessionID = activeSessionID {
            activeSessionID = nil
            Task { await sessionCoordinator.cancel(sessionID: sessionID) }
        }

        state = .idle
        transcript = ""
        level = 0
        resetTriggerLifecycle()
    }

    private func teardown() async {
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        _ = await feedTask?.value
        feedTask = nil
        await engine?.finish()
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        if let sessionID = activeSessionID {
            activeSessionID = nil
            await sessionCoordinator.cancel(sessionID: sessionID)
        }
        resetTriggerLifecycle()
        state = .idle
    }

    // MARK: - Helpers

    /// Replays the recording through every engine and files the results as one group.
    ///
    /// Nothing is injected in this mode — the point is to read the outputs side by side,
    /// and typing one of them into whatever had focus would be a surprise.
    private func runComparison() async {
        let chunks = recorded
        recorded.removeAll(keepingCapacity: false)

        guard !chunks.isEmpty, let holdStarted, let releasedAt else {
            resetTriggerLifecycle()
            state = .idle
            transcript = ""
            return
        }

        transcript = "Running both engines…"

        let group = UUID().uuidString
        let held = releasedAt.timeIntervalSince(holdStarted)
        let audioFile = AudioHistoryStore.save(chunks, id: UUID())

        // Filed one at a time as each engine finishes, so the window fills in progressively
        // rather than snapping both rows into place at the end.
        let results = await EngineComparison.run(chunks: chunks) { result in
            RunLog.record(
                DictationRun(
                    date: releasedAt,
                    engine: result.engine,
                    audioSeconds: held,
                    processSeconds: result.seconds,
                    text: result.text,
                    group: group,
                    audioFile: audioFile
                )
            )
        }

        for result in results {
            Log.speech.info("""
                compare · \(result.engine, privacy: .public): \
                \(result.seconds, format: .fixed(precision: 2))s — \
                \(result.text, privacy: .public)
                """)
        }

        self.holdStarted = nil
        self.releasedAt = nil
        isComparing = false
        resetTriggerLifecycle()
        state = .idle
        transcript = ""

        if Settings.shared.soundEnabled { NSSound(named: "Glass")?.play() }
    }

    /// Light smoothing so the waveform glides instead of strobing at buffer rate.
    private func updateLevel(_ new: Float) {
        level += (new - level) * 0.35
    }

    private func resetTriggerLifecycle() {
        activeTrigger = nil
        _ = handsFreePolicy.handle(.sessionEnded)
    }

    private func fail(_ message: String) {
        Log.app.error("\(message)")
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        if let sessionID = activeSessionID {
            activeSessionID = nil
            let failure = RecordingFailure(stage: .transcription, message: message)
            Task { await sessionCoordinator.fail(sessionID: sessionID, failure: failure) }
        }
        resetTriggerLifecycle()
        state = .error(message)
        level = 0

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if case .error = state { state = .idle }
        }
    }
}
