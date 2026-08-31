import Foundation
import MurmurAudioCore
import Observation

/// Which speech engine transcribes an utterance.
enum SpeechEngineChoice: String, CaseIterable, Sendable, Codable {
    case apple
    case parakeet

    var displayName: String {
        switch self {
        case .apple: "Apple (streaming)"
        case .parakeet: "Parakeet (batch)"
        }
    }

    /// Apple shows text while you talk; Parakeet only resolves on release.
    var showsLiveText: Bool { self == .apple }
}

struct HotkeyBindingSelection: Equatable {
    let pushToTalk: PushToTalkKey
    let handsFree: PushToTalkKey

    init(pushToTalk: PushToTalkKey, handsFree: PushToTalkKey) {
        self.pushToTalk = pushToTalk
        self.handsFree = handsFree == pushToTalk
            ? Self.fallback(excluding: pushToTalk)
            : handsFree
    }

    func selectingPushToTalk(_ key: PushToTalkKey) -> Self {
        Self(pushToTalk: key, handsFree: handsFree)
    }

    func selectingHandsFree(_ key: PushToTalkKey) -> Self {
        guard key != pushToTalk else { return self }
        return Self(pushToTalk: pushToTalk, handsFree: key)
    }

    private static func fallback(excluding key: PushToTalkKey) -> PushToTalkKey {
        PushToTalkKey.allCases.first(where: { $0 != key }) ?? .rightCommand
    }
}

struct SettingsSnapshot: Codable {
    let pushToTalkKey: String
    let engine: SpeechEngineChoice
    let compareMode: Bool
    let cleanupEnabled: Bool
    let smartCleanup: Bool
    let soundEnabled: Bool
    let handsFreeEnabled: Bool?
    let handsFreeKey: String?
    let microphoneSelection: MicrophoneSelection?
    let transcriptionLanguage: TranscriptionLanguageOption?

    var resolvedHandsFreeEnabled: Bool { handsFreeEnabled ?? false }
    var resolvedHandsFreeKey: PushToTalkKey {
        PushToTalkKey(rawValue: handsFreeKey ?? "") ?? .rightCommand
    }
    var resolvedMicrophoneSelection: MicrophoneSelection {
        microphoneSelection ?? .systemDefault
    }
    var resolvedTranscriptionLanguage: TranscriptionLanguageOption {
        transcriptionLanguage ?? .systemDefault
    }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    private(set) var pushToTalkKey: PushToTalkKey

    var handsFreeEnabled: Bool {
        didSet { persist() }
    }

    private(set) var handsFreeKey: PushToTalkKey

    var microphoneSelection: MicrophoneSelection {
        didSet { persist() }
    }

    var transcriptionLanguage: TranscriptionLanguageOption {
        didSet { persist() }
    }

    var engine: SpeechEngineChoice {
        didSet { persist() }
    }

    /// Run every engine on each recording and show them side by side, instead of
    /// transcribing with one. Nothing is typed into the focused app in this mode.
    var compareMode: Bool {
        didSet { persist() }
    }

    /// Run the cleanup pass before injecting. Off = raw engine output.
    var cleanupEnabled: Bool {
        didSet { persist() }
    }

    /// Use the on-device LLM for cleanup instead of the deterministic rule pass.
    var smartCleanup: Bool {
        didSet { persist() }
    }

    /// Play a short tick when capture starts and stops.
    var soundEnabled: Bool {
        didSet { persist() }
    }

    private let defaults = UserDefaults.standard
    private var isHydrating = false

    private enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        static let handsFreeEnabled = "handsFreeEnabled"
        static let handsFreeKey = "handsFreeKey"
        static let microphoneSelection = "microphoneSelection"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        static let smartCleanup = "smartCleanup"
        static let compareMode = "compareMode"
    }

    private init() {
        let snapshot = Self.loadSnapshot()
        let pushToTalkRaw = snapshot?.pushToTalkKey
            ?? defaults.string(forKey: Keys.pushToTalkKey)
            ?? PushToTalkKey.rightOption.rawValue
        let requestedPushToTalk = PushToTalkKey(rawValue: pushToTalkRaw) ?? .rightOption
        let requestedHandsFree = snapshot?.resolvedHandsFreeKey
            ?? PushToTalkKey(rawValue: defaults.string(forKey: Keys.handsFreeKey) ?? "")
            ?? .rightCommand
        let selection = HotkeyBindingSelection(
            pushToTalk: requestedPushToTalk,
            handsFree: requestedHandsFree
        )
        pushToTalkKey = selection.pushToTalk
        handsFreeKey = selection.handsFree
        handsFreeEnabled = snapshot?.resolvedHandsFreeEnabled
            ?? (defaults.object(forKey: Keys.handsFreeEnabled) as? Bool ?? false)
        if let snapshot {
            microphoneSelection = snapshot.resolvedMicrophoneSelection
        } else if let data = defaults.data(forKey: Keys.microphoneSelection),
                  let decoded = try? JSONDecoder().decode(MicrophoneSelection.self, from: data) {
            microphoneSelection = decoded
        } else {
            microphoneSelection = .systemDefault
        }
        transcriptionLanguage = snapshot?.resolvedTranscriptionLanguage
            ?? TranscriptionLanguageOption(
                rawValue: defaults.string(forKey: Keys.transcriptionLanguage) ?? ""
            )
            ?? .systemDefault
        // Apple by default: no download, no dependency, live text while speaking.
        engine = snapshot?.engine
            ?? SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "")
            ?? .apple
        cleanupEnabled = snapshot?.cleanupEnabled
            ?? (defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true)
        smartCleanup = snapshot?.smartCleanup
            ?? (defaults.object(forKey: Keys.smartCleanup) as? Bool ?? false)
        compareMode = snapshot?.compareMode
            ?? (defaults.object(forKey: Keys.compareMode) as? Bool ?? false)
        soundEnabled = snapshot?.soundEnabled
            ?? (defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true)

        // External settings are hydrated off the launch path. The removable volume can take
        // an unbounded amount of time to answer its first file open, so the window starts with
        // the last local preference snapshot and adopts the external snapshot when it arrives.
    }

    private static func loadSnapshot() -> SettingsSnapshot? {
        let defaults = UserDefaults.standard
        let hasAnyValue = [
            Keys.pushToTalkKey,
            Keys.handsFreeEnabled,
            Keys.handsFreeKey,
            Keys.microphoneSelection,
            Keys.transcriptionLanguage,
            Keys.cleanupEnabled,
            Keys.soundEnabled,
            Keys.engine,
            Keys.smartCleanup,
            Keys.compareMode
        ].contains { defaults.object(forKey: $0) != nil }
        guard hasAnyValue else { return nil }

        return SettingsSnapshot(
            pushToTalkKey: defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.rightOption.rawValue,
            engine: SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple,
            compareMode: defaults.object(forKey: Keys.compareMode) as? Bool ?? false,
            cleanupEnabled: defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true,
            smartCleanup: defaults.object(forKey: Keys.smartCleanup) as? Bool ?? false,
            soundEnabled: defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true,
            handsFreeEnabled: defaults.object(forKey: Keys.handsFreeEnabled) as? Bool,
            handsFreeKey: defaults.string(forKey: Keys.handsFreeKey),
            microphoneSelection: defaults.data(forKey: Keys.microphoneSelection)
                .flatMap { try? JSONDecoder().decode(MicrophoneSelection.self, from: $0) },
            transcriptionLanguage: TranscriptionLanguageOption(
                rawValue: defaults.string(forKey: Keys.transcriptionLanguage) ?? ""
            )
        )
    }

    /// Reads the authoritative external snapshot without blocking the app's launch thread.
    /// The task may outlive a slow or sleeping drive; that is preferable to making the first
    /// window wait on removable storage.
    static func beginDeferredHydration() {
        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: MurmureDataStore.settingsURL),
                  let snapshot = try? JSONDecoder().decode(SettingsSnapshot.self, from: data) else {
                return
            }
            await MainActor.run {
                let settings = Settings.shared
                settings.isHydrating = true
                let selection = HotkeyBindingSelection(
                    pushToTalk: PushToTalkKey(rawValue: snapshot.pushToTalkKey) ?? .rightOption,
                    handsFree: snapshot.resolvedHandsFreeKey
                )
                settings.pushToTalkKey = selection.pushToTalk
                settings.handsFreeKey = selection.handsFree
                settings.handsFreeEnabled = snapshot.resolvedHandsFreeEnabled
                settings.microphoneSelection = snapshot.resolvedMicrophoneSelection
                settings.transcriptionLanguage = snapshot.resolvedTranscriptionLanguage
                settings.engine = snapshot.engine
                settings.compareMode = snapshot.compareMode
                settings.cleanupEnabled = snapshot.cleanupEnabled
                settings.smartCleanup = snapshot.smartCleanup
                settings.soundEnabled = snapshot.soundEnabled
                settings.isHydrating = false
                // Keep a local fallback for the next launch without synchronously rewriting
                // the external file from the main actor. The authoritative snapshot is
                // already on disk and future user edits still use `persist()`.
                settings.defaults.set(settings.pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey)
                settings.defaults.set(settings.handsFreeEnabled, forKey: Keys.handsFreeEnabled)
                settings.defaults.set(settings.handsFreeKey.rawValue, forKey: Keys.handsFreeKey)
                if let microphoneData = try? JSONEncoder().encode(settings.microphoneSelection) {
                    settings.defaults.set(microphoneData, forKey: Keys.microphoneSelection)
                }
                settings.defaults.set(
                    settings.transcriptionLanguage.rawValue,
                    forKey: Keys.transcriptionLanguage
                )
                settings.defaults.set(settings.engine.rawValue, forKey: Keys.engine)
                settings.defaults.set(settings.compareMode, forKey: Keys.compareMode)
                settings.defaults.set(settings.cleanupEnabled, forKey: Keys.cleanupEnabled)
                settings.defaults.set(settings.smartCleanup, forKey: Keys.smartCleanup)
                settings.defaults.set(settings.soundEnabled, forKey: Keys.soundEnabled)
            }
        }
    }

    func selectPushToTalkKey(_ key: PushToTalkKey) {
        apply(HotkeyBindingSelection(
            pushToTalk: pushToTalkKey,
            handsFree: handsFreeKey
        ).selectingPushToTalk(key))
    }

    func selectHandsFreeKey(_ key: PushToTalkKey) {
        apply(HotkeyBindingSelection(
            pushToTalk: pushToTalkKey,
            handsFree: handsFreeKey
        ).selectingHandsFree(key))
    }

    private func apply(_ selection: HotkeyBindingSelection) {
        isHydrating = true
        pushToTalkKey = selection.pushToTalk
        handsFreeKey = selection.handsFree
        isHydrating = false
        persist()
    }

    private func persist() {
        guard !isHydrating else { return }
        let snapshot = SettingsSnapshot(
            pushToTalkKey: pushToTalkKey.rawValue,
            engine: engine,
            compareMode: compareMode,
            cleanupEnabled: cleanupEnabled,
            smartCleanup: smartCleanup,
            soundEnabled: soundEnabled,
            handsFreeEnabled: handsFreeEnabled,
            handsFreeKey: handsFreeKey.rawValue,
            microphoneSelection: microphoneSelection,
            transcriptionLanguage: transcriptionLanguage
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(snapshot.pushToTalkKey, forKey: Keys.pushToTalkKey)
        defaults.set(snapshot.resolvedHandsFreeEnabled, forKey: Keys.handsFreeEnabled)
        defaults.set(snapshot.resolvedHandsFreeKey.rawValue, forKey: Keys.handsFreeKey)
        if let microphoneData = try? JSONEncoder().encode(snapshot.resolvedMicrophoneSelection) {
            defaults.set(microphoneData, forKey: Keys.microphoneSelection)
        }
        defaults.set(snapshot.resolvedTranscriptionLanguage.rawValue, forKey: Keys.transcriptionLanguage)
        defaults.set(snapshot.engine.rawValue, forKey: Keys.engine)
        defaults.set(snapshot.compareMode, forKey: Keys.compareMode)
        defaults.set(snapshot.cleanupEnabled, forKey: Keys.cleanupEnabled)
        defaults.set(snapshot.smartCleanup, forKey: Keys.smartCleanup)
        defaults.set(snapshot.soundEnabled, forKey: Keys.soundEnabled)
        let url = MurmureDataStore.settingsURL
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
