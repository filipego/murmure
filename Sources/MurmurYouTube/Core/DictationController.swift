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
        makeTranscriptionEngine(
            choice: Settings.shared.engine,
            language: Settings.shared.transcriptionLanguage.selection
        )
    }
}

@Sendable
func makeTranscriptionEngine(
    choice: SpeechEngineChoice,
    language: TranscriptionLanguageSelection
) -> any TranscriptionEngine {
    switch resolvedEngineChoice(preferred: choice, language: language) {
    case .apple: AppleSpeechEngine(language: language)
    case .parakeet: ParakeetEngine(language: language)
    }
}

func resolvedEngineChoice(
    preferred: SpeechEngineChoice,
    language: TranscriptionLanguageSelection
) -> SpeechEngineChoice {
    if case .systemDefault = language { return .parakeet }
    return preferred
}

enum LiveTypingPolicy {
    static func isEnabled(
        timing: TextInsertionTiming,
        engine: SpeechEngineChoice,
        compareMode: Bool
    ) -> Bool {
        timing == .whileSpeaking && engine == .apple && !compareMode
    }
}

enum LiveTypingCompletionPolicy {
    static func shouldUseOneShotInsertion(
        disposition: LiveTextFinalization,
        operationIsCurrent: Bool
    ) -> Bool {
        operationIsCurrent && disposition == .useOneShotInsertion
    }
}

enum DictationStartEntryPoint: CaseIterable, Sendable {
    case primary
    case button
    case commandMode
    case handsFree
}

enum DictationStartPolicy {
    static func canBegin(
        entryPoint: DictationStartEntryPoint,
        visibleState: DictationController.State,
        lifecycleCanBegin: Bool
    ) -> Bool {
        switch entryPoint {
        case .primary, .button, .commandMode, .handsFree:
            return visibleState == .idle && lifecycleCanBegin
        }
    }
}

enum HandsFreeEventRoutingPolicy {
    static func handle(
        _ event: HandsFreeGesturePolicy.Event,
        policy: inout HandsFreeGesturePolicy,
        canBegin: Bool
    ) -> HandsFreeGesturePolicy.Command {
        if event == .bindingPressed,
           !policy.isActive,
           !canBegin {
            return .ignore
        }
        return policy.handle(event)
    }
}

struct DictationOperationToken: Equatable, Sendable {
    fileprivate let id: UUID
}

struct DictationCancellationToken: Equatable, Sendable {
    fileprivate let id: UUID
}

struct DictationOperationLifecycle: Sendable {
    private var current: DictationOperationToken?
    private var cancellation: DictationCancellationToken?

    var currentToken: DictationOperationToken? { current }
    var canBegin: Bool { current == nil && cancellation == nil }
    var hasPendingCancellation: Bool { cancellation != nil }

    mutating func begin() -> DictationOperationToken {
        precondition(canBegin)
        let token = DictationOperationToken(id: UUID())
        current = token
        return token
    }

    mutating func beginCancellation() -> DictationCancellationToken {
        precondition(cancellation == nil)
        current = nil
        let token = DictationCancellationToken(id: UUID())
        cancellation = token
        return token
    }

    mutating func invalidate() {
        current = nil
    }

    func isCurrent(_ token: DictationOperationToken) -> Bool {
        current == token
    }

    func isCancelling(_ token: DictationCancellationToken) -> Bool {
        cancellation == token
    }

    @discardableResult
    mutating func completeCancellation(_ token: DictationCancellationToken) -> Bool {
        guard cancellation == token else { return false }
        cancellation = nil
        return true
    }
}

private struct LiveTranscriptionConfiguration {
    let engine: SpeechEngineChoice
    let language: TranscriptionLanguageOption
    let insertionTiming: TextInsertionTiming
    let cleanupEnabled: Bool
    let smartCleanup: Bool
}

private struct StoppedDictationResources {
    let engine: (any TranscriptionEngine)?
    let liveInsertion: LiveTextInsertionSession?
    let sessionID: UUID?
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
    let commandMode = LocalCommandController()

    private let hotkey = HotkeyMonitor()
    private let capture = AudioCapture()
    private let makeEngine: (@Sendable () -> any TranscriptionEngine)?
    private let sessionCoordinator: RecordingSessionCoordinator
    private var wantsHotkeyActive = false
    private var isHotkeySuspendedForModalInput = false
    private var handsFreePolicy = HandsFreeGesturePolicy()
    private var primaryGesturePolicy = HotkeyGesturePolicy(gesture: .hold)
    private var activeTrigger: RecordingTrigger?

    var canStartButtonRecording: Bool {
        guard !isHotkeySuspendedForModalInput else { return false }
        return canBeginRecordingLikeAction(.button)
    }

    /// Injected only by tests; production reads the setting per-utterance below.
    private let formatter: (any TextFormatter)?

    /// Chosen per-utterance so the menu toggle applies to the very next hold.
    private func activeFormatter(for configuration: LiveTranscriptionConfiguration) -> any TextFormatter {
        if let formatter { return formatter }
        let profile = configuration.language.cleanupProfile
        return configuration.smartCleanup && FoundationModelFormatter.supports(profile)
            ? FoundationModelFormatter(profile: profile)
            : RuleBasedFormatter(profile: profile)
    }

    private var engine: (any TranscriptionEngine)?
    private var startupTask: Task<Void, Never>?
    private var finishingTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
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
    private var activeConfiguration: LiveTranscriptionConfiguration?
    private var liveInsertion: LiveTextInsertionSession?
    private var operationLifecycle = DictationOperationLifecycle()

    init(
        formatter: (any TextFormatter)? = nil,
        makeEngine: (@Sendable () -> any TranscriptionEngine)? = nil,
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
        let primaryBinding = Settings.shared.pushToTalkBinding
        hotkey.binding = primaryBinding
        hotkey.handsFreeBinding = Settings.shared.handsFreeEnabled
            ? Settings.shared.handsFreeBinding
            : nil
        hotkey.commandModeBinding = Settings.shared.commandModeEnabled
            ? Settings.shared.commandModeBinding
            : nil
        primaryGesturePolicy = HotkeyGesturePolicy(gesture: primaryBinding.gesture)
        hotkey.onPress = { [weak self] in
            self?.handlePrimaryBinding(.pressed(at: Date.timeIntervalSinceReferenceDate))
        }
        hotkey.onRelease = { [weak self] in
            self?.handlePrimaryBinding(.released(at: Date.timeIntervalSinceReferenceDate))
        }
        hotkey.handsFreeSessionIsActive = handsFreePolicy.isActive
        hotkey.onHandsFreeToggle = { [weak self] in
            self?.handleHandsFree(.bindingPressed)
        }
        hotkey.onHandsFreeFinish = { [weak self] in
            self?.handleHandsFree(.enterPressed)
        }
        hotkey.onHandsFreeCancel = { [weak self] in
            self?.handleHandsFree(.escapePressed)
        }
        hotkey.onCommandModePress = { [weak self] in
            guard let self,
                  self.canBeginRecordingLikeAction(.commandMode)
            else { return }
            self.commandMode.begin()
        }
        hotkey.onCommandModeRelease = { [weak self] in
            self?.commandMode.finish()
        }
        return hotkey.start()
    }

    func deactivate() {
        wantsHotkeyActive = false
        hotkey.stop()
        cancelDictation()
        commandMode.cancel()
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
        beginDictation(trigger: .mainButton, entryPoint: .button)
    }

    func stopButtonRecording() {
        endDictation()
    }

    private func endHoldToTalkDictation() {
        guard case .holdToTalk = activeTrigger else { return }
        endDictation()
    }

    private func handlePrimaryBinding(_ edge: HotkeyGesturePolicy.Edge) {
        if activeTrigger == nil,
           !canBeginRecordingLikeAction(.primary) {
            return
        }

        switch primaryGesturePolicy.handle(edge) {
        case .start:
            beginDictation(
                trigger: .holdToTalk(bindingID: Settings.shared.pushToTalkBinding.id),
                entryPoint: .primary
            )
        case .finish:
            endHoldToTalkDictation()
        case .ignore:
            break
        }
    }

    private func handleHandsFree(_ event: HandsFreeGesturePolicy.Event) {
        let command = HandsFreeEventRoutingPolicy.handle(
            event,
            policy: &handsFreePolicy,
            canBegin: canBeginRecordingLikeAction(.handsFree)
        )
        switch command {
        case .start:
            beginDictation(
                trigger: .handsFree(bindingID: Settings.shared.handsFreeBinding.id),
                entryPoint: .handsFree
            )
        case .finish:
            endDictation()
        case .cancel:
            cancelDictation()
        case .ignore:
            break
        }
        hotkey.handsFreeSessionIsActive = handsFreePolicy.isActive
    }

    // MARK: - Dictation

    private func beginDictation(
        trigger: RecordingTrigger,
        entryPoint: DictationStartEntryPoint
    ) {
        guard canBeginRecordingLikeAction(entryPoint),
              !commandMode.isBusy,
              liveInsertion == nil
        else { return }
        let operation = operationLifecycle.begin()
        state = .starting
        activeTrigger = trigger
        transcript = ""
        let startedAt = Date()
        holdStarted = startedAt
        let compareMode = Settings.shared.compareMode
        isComparing = compareMode
        activeSessionID = nil
        recorded.removeAll(keepingCapacity: true)
        let configuration = LiveTranscriptionConfiguration(
            engine: resolvedEngineChoice(
                preferred: Settings.shared.engine,
                language: Settings.shared.transcriptionLanguage.selection
            ),
            language: Settings.shared.transcriptionLanguage,
            insertionTiming: Settings.shared.textInsertionTiming,
            cleanupEnabled: Settings.shared.cleanupEnabled,
            smartCleanup: Settings.shared.smartCleanup
        )
        activeConfiguration = configuration
        engineName = compareMode ? "Comparing…" : configuration.engine.displayName
        let liveInsertion = LiveTypingPolicy.isEnabled(
            timing: configuration.insertionTiming,
            engine: configuration.engine,
            compareMode: compareMode
        ) ? LiveTextInsertionSession() : nil
        self.liveInsertion = liveInsertion
        let microphoneSelection = Settings.shared.microphoneSelection
        let soundEnabled = Settings.shared.soundEnabled

        startupTask = Task { @MainActor [weak self] in
            guard let self else {
                await liveInsertion?.cancel()
                return
            }
            var startedEngine: (any TranscriptionEngine)?
            var begunSessionID: UUID?
            do {
                let hasMicrophonePermission = await Permissions.requestMicrophone()
                guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                    await self.abandonStaleStartup(
                        liveInsertion: liveInsertion,
                        engine: startedEngine,
                        sessionID: begunSessionID
                    )
                    return
                }
                guard hasMicrophonePermission else {
                    self.fail(
                        "Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.",
                        operation: operation,
                        liveInsertion: liveInsertion
                    )
                    return
                }

                if !compareMode {
                    let engineID: SessionEngineID = configuration.engine == .apple ? .apple : .parakeet
                    let session = try await sessionCoordinator.begin(
                        startedAt: startedAt,
                        trigger: trigger,
                        engine: engineID,
                        language: configuration.language.selection
                    )
                    begunSessionID = session.id
                    guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                        await self.abandonStaleStartup(
                            liveInsertion: liveInsertion,
                            engine: startedEngine,
                            sessionID: begunSessionID
                        )
                        return
                    }
                    activeSessionID = session.id
                }

                let engine = makeEngine?() ?? makeTranscriptionEngine(
                        choice: configuration.engine,
                        language: configuration.language.selection
                    )
                startedEngine = engine
                self.engine = engine

                let chunks = try await engine.start()
                guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                    await self.abandonStaleStartup(
                        liveInsertion: liveInsertion,
                        engine: startedEngine,
                        sessionID: begunSessionID
                    )
                    return
                }

                // Compare mode captures in *Apple's* format, not a format of our choosing.
                //
                // SpeechAnalyzer enforces `Audio sample data must be 16-bit signed integers`
                // as a hard precondition — feeding it float32 doesn't fail gracefully, it
                // kills the process. Parakeet is the flexible one (its `feed` converts
                // int16/int32/float32), so the strict engine picks the format and the
                // tolerant engine adapts. Both still replay the identical buffers.
                let formatOwner: any TranscriptionEngine = compareMode
                    ? AppleSpeechEngine(language: configuration.language.selection)
                    : engine
                let preferredFormat = await formatOwner.preferredInputFormat()
                guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                    await self.abandonStaleStartup(
                        liveInsertion: liveInsertion,
                        engine: startedEngine,
                        sessionID: begunSessionID
                    )
                    return
                }
                guard let format = preferredFormat else {
                    throw TranscriptionError.noAudioFormat
                }
                let liveInput = try LiveAudioInputResolver.resolve(
                    microphoneSelection
                )
                if case .fallback = liveInput.resolution {
                    Log.audio.error("\(liveInput.resolution.statusText, privacy: .public)")
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
                    deviceID: liveInput.objectID,
                    outputFormat: format,
                    onBuffer: { chunk in
                        audioContinuation.yield(chunk)
                    },
                    onLevel: { [weak self] level in
                        Task { @MainActor in
                            guard let self,
                                  self.operationLifecycle.isCurrent(operation)
                            else { return }
                            self.updateLevel(level)
                        }
                    },
                    onDeviceChange: { [weak self] in
                        Task { @MainActor in
                            self?.handleAudioInputChange(
                                liveInput.device.displayName,
                                operation: operation,
                                liveInsertion: liveInsertion
                            )
                        }
                    }
                )

                // Bail out if the user already let go while we were spinning up.
                guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                    await self.abandonStaleStartup(
                        liveInsertion: liveInsertion,
                        engine: startedEngine,
                        sessionID: begunSessionID
                    )
                    return
                }
                guard case .starting = self.state else {
                    self.cancelDictation()
                    return
                }

                self.state = .listening
                if soundEnabled { NSSound(named: "Tink")?.play() }

                self.consumeTask = Task { @MainActor in
                    do {
                        for try await chunk in chunks {
                            guard self.operationLifecycle.isCurrent(operation),
                                  !Task.isCancelled
                            else { return }
                            self.transcript = chunk.text
                            await liveInsertion?.render(chunk.text)
                        }
                    } catch {
                        guard self.operationLifecycle.isCurrent(operation),
                              !Task.isCancelled
                        else { return }
                        self.fail(
                            error.localizedDescription,
                            operation: operation,
                            liveInsertion: liveInsertion
                        )
                    }
                }
                self.startupTask = nil
            } catch {
                guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                    await self.abandonStaleStartup(
                        liveInsertion: liveInsertion,
                        engine: startedEngine,
                        sessionID: begunSessionID
                    )
                    return
                }
                self.fail(
                    error.localizedDescription,
                    operation: operation,
                    liveInsertion: liveInsertion
                )
            }
        }
    }

    private func canBeginRecordingLikeAction(
        _ entryPoint: DictationStartEntryPoint
    ) -> Bool {
        DictationStartPolicy.canBegin(
            entryPoint: entryPoint,
            visibleState: state,
            lifecycleCanBegin: operationLifecycle.canBegin
        )
    }

    private func endDictation() {
        if handsFreePolicy.isActive,
           case .handsFree = activeTrigger {
            _ = handsFreePolicy.handle(.enterPressed)
            hotkey.handsFreeSessionIsActive = handsFreePolicy.isActive
        }

        // `.finishing` is "active", so without this a second press during processing would
        // run the whole tail again — re-reading `transcript` before the first pass cleared
        // it and pasting the same utterance twice. The window is wide: Parakeet transcribes
        // inside `finish()`, and smart cleanup adds up to 4s on top.
        guard state.isActive, state != .finishing else { return }
        guard state != .starting else {
            cancelDictation()
            return
        }
        guard let operation = operationLifecycle.currentToken else { return }
        state = .finishing
        capture.stop()
        level = 0
        let releasedAt = Date()
        self.releasedAt = releasedAt

        audioContinuation?.finish()
        audioContinuation = nil
        let feedTask = self.feedTask
        let engine = self.engine
        let consumeTask = self.consumeTask
        let sessionID = activeSessionID
        let configuration = activeConfiguration
        let startedAt = holdStarted
        let completedEngineName = engineName
        let compareMode = isComparing
        let liveInsertion = self.liveInsertion
        let soundEnabled = Settings.shared.soundEnabled

        finishingTask = Task { @MainActor [weak self] in
            guard let self else {
                await liveInsertion?.cancel()
                return
            }
            // Drain every captured buffer into the engine before asking it to finalize,
            // or the tail of the utterance gets dropped.
            let recording = await feedTask?.value ?? []
            guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                return
            }
            self.recorded = recording
            self.feedTask = nil

            await engine?.finish()
            guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                return
            }
            await consumeTask?.value
            guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                return
            }
            self.consumeTask = nil
            self.engine = nil

            if compareMode {
                await self.runComparison(
                    chunks: recording,
                    startedAt: startedAt,
                    releasedAt: releasedAt,
                    language: configuration?.language.selection ?? .systemDefault,
                    operation: operation
                )
                return
            }

            guard let sessionID else {
                self.fail(
                    "The recording session could not be recovered.",
                    operation: operation,
                    liveInsertion: liveInsertion
                )
                return
            }

            do {
                _ = try await self.sessionCoordinator.stageReleasedAudio(
                    sessionID: sessionID,
                    chunks: recording,
                    releasedAt: releasedAt
                )
            } catch {
                guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                    return
                }
                self.activeSessionID = nil
                self.fail(
                    "The recording was retained locally, but audio staging failed: \(error.localizedDescription)",
                    operation: operation,
                    liveInsertion: liveInsertion
                )
                return
            }
            guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                return
            }

            let raw = self.transcript
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await liveInsertion?.cancel()
                guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                    return
                }
                self.clearLiveInsertion(ifMatching: liveInsertion)
                _ = try? await self.sessionCoordinator.persistProcessedText(
                    sessionID: sessionID,
                    finalText: raw
                )
                guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                    return
                }
                self.finishOperation(operation, liveInsertion: liveInsertion)
                return
            }

            guard let configuration else {
                self.fail(
                    "The recording language configuration could not be recovered.",
                    operation: operation,
                    liveInsertion: liveInsertion
                )
                return
            }
            let cleaned = configuration.cleanupEnabled
                ? await self.activeFormatter(for: configuration).format(raw)
                : raw
            guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                return
            }
            let expansion = SnippetStore.shared.expander.expand(cleaned)
            if expansion.applied != nil {
                Log.speech.info("snippet · exact whole-utterance replacement applied")
            }

            // The dictionary runs last, and runs regardless of the cleanup setting. Biasing
            // only raises the odds of the right word; this is the pass that guarantees it,
            // so it must not be something the user can accidentally switch off.
            let (output, corrections) = DictionaryStore.shared.corrector.apply(to: expansion.text)
            if !corrections.isEmpty {
                Log.speech.info("dictionary · \(corrections.count, privacy: .public) correction(s) applied")
            }

            do {
                _ = try await self.sessionCoordinator.persistProcessedText(
                    sessionID: sessionID,
                    finalText: output
                )
            } catch {
                guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                    return
                }
                self.fail(
                    "The transcript could not be made durable: \(error.localizedDescription)",
                    operation: operation,
                    liveInsertion: liveInsertion
                )
                return
            }
            guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                return
            }

            let run = DictationRun(
                id: sessionID,
                date: releasedAt,
                engine: completedEngineName,
                language: configuration.language.selection,
                audioSeconds: releasedAt.timeIntervalSince(startedAt ?? releasedAt),
                processSeconds: Date().timeIntervalSince(releasedAt),
                text: output,
                corrections: corrections.isEmpty ? nil : corrections,
                appliedSnippet: expansion.applied
            )
            guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                return
            }
            let disposition = await liveInsertion?.finalize(output)
                ?? .useOneShotInsertion
            guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                return
            }
            let completed = await self.sessionCoordinator.completeLiveSession(
                sessionID: sessionID,
                run: run,
                insert: { [weak self] text in
                    guard let self,
                          LiveTypingCompletionPolicy.shouldUseOneShotInsertion(
                            disposition: disposition,
                            operationIsCurrent: self.operationLifecycle.isCurrent(operation)
                          )
                    else { return }
                    TextInjector.insert(text)
                }
            )
            guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                return
            }
            self.activeSessionID = nil
            guard completed else {
                self.fail(
                    "The transcript is safe locally and will be retried from history recovery.",
                    operation: operation,
                    liveInsertion: liveInsertion
                )
                return
            }
            await liveInsertion?.commit()
            guard self.operationLifecycle.isCurrent(operation), !Task.isCancelled else {
                return
            }
            if disposition == .retainedInHistoryOnly {
                self.fail(
                    L10n.text(
                        "Live typing stopped because the destination changed. Your final text is saved in History."
                    ),
                    operation: operation,
                    liveInsertion: liveInsertion
                )
                return
            }
            self.clearLiveInsertion(ifMatching: liveInsertion)
            if soundEnabled { NSSound(named: "Pop")?.play() }
            self.finishOperation(operation, liveInsertion: liveInsertion)
        }
    }

    private func cancelDictation() {
        guard !operationLifecycle.hasPendingCancellation else { return }
        guard state != .idle || operationLifecycle.currentToken != nil || liveInsertion != nil else {
            return
        }

        let cancellation = operationLifecycle.beginCancellation()
        state = .idle
        let stopped = stopCurrentOperation(liveInsertion: liveInsertion)
        Task { await stopped.engine?.finish() }
        if let sessionID = stopped.sessionID {
            Task { await sessionCoordinator.cancel(sessionID: sessionID) }
        }

        transcript = ""
        level = 0
        holdStarted = nil
        releasedAt = nil
        resetTriggerLifecycle()
        trackLiveInsertionCancellation(
            stopped.liveInsertion,
            cancellation: cancellation
        )
    }

    // MARK: - Helpers

    /// Replays the recording through every engine and files the results as one group.
    ///
    /// Nothing is injected in this mode — the point is to read the outputs side by side,
    /// and typing one of them into whatever had focus would be a surprise.
    private func runComparison(
        chunks: [AudioChunk],
        startedAt: Date?,
        releasedAt: Date,
        language: TranscriptionLanguageSelection,
        operation: DictationOperationToken
    ) async {
        guard operationLifecycle.isCurrent(operation), !Task.isCancelled else { return }
        recorded.removeAll(keepingCapacity: false)

        guard !chunks.isEmpty, let startedAt else {
            finishOperation(operation, liveInsertion: nil)
            return
        }

        transcript = "Running both engines…"

        let group = UUID().uuidString
        let held = releasedAt.timeIntervalSince(startedAt)
        let audioFile = AudioHistoryStore.save(chunks, id: UUID())

        // Filed one at a time as each engine finishes, so the window fills in progressively
        // rather than snapping both rows into place at the end.
        let results = await EngineComparison.run(chunks: chunks, language: language) { [weak self] result in
            guard let self, self.operationLifecycle.isCurrent(operation) else { return }
            RunLog.record(
                DictationRun(
                    date: releasedAt,
                    engine: result.engine,
                    language: language,
                    audioSeconds: held,
                    processSeconds: result.seconds,
                    text: result.text,
                    group: group,
                    audioFile: audioFile
                )
            )
        }
        guard operationLifecycle.isCurrent(operation), !Task.isCancelled else { return }

        for result in results {
            Log.speech.info("""
                compare · \(result.engine, privacy: .public): \
                \(result.seconds, format: .fixed(precision: 2))s — \
                \(result.text, privacy: .public)
                """)
        }
        isComparing = false
        if Settings.shared.soundEnabled { NSSound(named: "Glass")?.play() }
        finishOperation(operation, liveInsertion: nil)
    }

    /// Light smoothing so the waveform glides instead of strobing at buffer rate.
    private func updateLevel(_ new: Float) {
        level += (new - level) * 0.35
    }

    private func handleAudioInputChange(
        _ deviceName: String,
        operation: DictationOperationToken,
        liveInsertion: LiveTextInsertionSession?
    ) {
        guard operationLifecycle.isCurrent(operation),
              state == .starting || state == .listening
        else { return }
        fail(
            "\(deviceName) changed or disconnected. This recording stopped safely; try again to re-resolve the microphone.",
            operation: operation,
            liveInsertion: liveInsertion
        )
    }

    private func resetTriggerLifecycle() {
        activeTrigger = nil
        activeConfiguration = nil
        primaryGesturePolicy.reset()
        _ = handsFreePolicy.handle(.sessionEnded)
        hotkey.handsFreeSessionIsActive = false
    }

    private func abandonStaleStartup(
        liveInsertion: LiveTextInsertionSession?,
        engine: (any TranscriptionEngine)?,
        sessionID: UUID?
    ) async {
        await engine?.finish()
        if let sessionID {
            await sessionCoordinator.cancel(sessionID: sessionID)
        }
        await liveInsertion?.cancel()
    }

    private func trackLiveInsertionCancellation(
        _ capturedSession: LiveTextInsertionSession?,
        cancellation: DictationCancellationToken
    ) {
        cancellationTask = Task { @MainActor [weak self] in
            await capturedSession?.cancel()
            guard let self else { return }
            self.clearLiveInsertion(ifMatching: capturedSession)
            guard self.operationLifecycle.completeCancellation(cancellation) else { return }
            self.cancellationTask = nil
        }
    }

    private func clearLiveInsertion(ifMatching session: LiveTextInsertionSession?) {
        guard let session,
              let current = liveInsertion,
              current === session
        else { return }
        liveInsertion = nil
    }

    private func stopCurrentOperation(
        liveInsertion ownedLiveInsertion: LiveTextInsertionSession?
    ) -> StoppedDictationResources {
        startupTask?.cancel()
        startupTask = nil
        finishingTask?.cancel()
        finishingTask = nil

        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil

        let stopped = StoppedDictationResources(
            engine: engine,
            liveInsertion: ownedLiveInsertion ?? liveInsertion,
            sessionID: activeSessionID
        )
        engine = nil
        activeSessionID = nil
        return stopped
    }

    private func finishOperation(
        _ operation: DictationOperationToken,
        liveInsertion: LiveTextInsertionSession?
    ) {
        guard operationLifecycle.isCurrent(operation) else { return }
        operationLifecycle.invalidate()
        startupTask = nil
        finishingTask = nil
        activeSessionID = nil
        clearLiveInsertion(ifMatching: liveInsertion)
        holdStarted = nil
        releasedAt = nil
        resetTriggerLifecycle()
        state = .idle
        transcript = ""
    }

    private func fail(
        _ message: String,
        operation: DictationOperationToken? = nil,
        liveInsertion: LiveTextInsertionSession? = nil
    ) {
        if let operation, !operationLifecycle.isCurrent(operation) { return }
        Log.app.error("\(message)")
        let cancellation = operationLifecycle.beginCancellation()
        let stopped = stopCurrentOperation(liveInsertion: liveInsertion)
        Task { await stopped.engine?.finish() }
        if let sessionID = stopped.sessionID {
            let failure = RecordingFailure(stage: .transcription, message: message)
            Task { await sessionCoordinator.fail(sessionID: sessionID, failure: failure) }
        }
        trackLiveInsertionCancellation(
            stopped.liveInsertion,
            cancellation: cancellation
        )
        let cancellationTask = self.cancellationTask
        resetTriggerLifecycle()
        state = .error(message)
        level = 0

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await cancellationTask?.value
            if state == .error(message), operationLifecycle.canBegin { state = .idle }
        }
    }
}
