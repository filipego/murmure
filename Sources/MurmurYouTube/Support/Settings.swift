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

struct HotkeyBindingRegistry: Equatable {
    let pushToTalk: HotkeyBinding
    let handsFree: HotkeyBinding

    init(pushToTalk: HotkeyBinding, handsFree: HotkeyBinding) {
        let safePrimary = HotkeyBindingValidator.issues(for: pushToTalk).contains {
            $0.severity == .error
        } ? PushToTalkKey.rightOption.binding(gesture: .hold) : pushToTalk

        let handsFreeIsInvalid = HotkeyBindingValidator.issues(for: handsFree).contains {
            $0.severity == .error
        }
        let candidates = [
            handsFreeIsInvalid ? nil : handsFree.withGesture(.toggle),
            PushToTalkKey.rightCommand.binding(gesture: .toggle),
            PushToTalkKey.fn.binding(gesture: .toggle),
            PushToTalkKey.rightOption.binding(gesture: .toggle)
        ].compactMap { $0 }

        self.pushToTalk = safePrimary
        self.handsFree = candidates.first { $0.id != safePrimary.id }
            ?? PushToTalkKey.rightCommand.binding(gesture: .toggle)
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
    let pushToTalkBinding: HotkeyBinding?
    let handsFreeBinding: HotkeyBinding?

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
    var resolvedPushToTalkBinding: HotkeyBinding {
        pushToTalkBinding
            ?? (PushToTalkKey(rawValue: pushToTalkKey) ?? .rightOption).binding(gesture: .hold)
    }
    var resolvedHandsFreeBinding: HotkeyBinding {
        handsFreeBinding ?? resolvedHandsFreeKey.binding(gesture: .toggle)
    }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    private(set) var pushToTalkKey: PushToTalkKey
    private(set) var pushToTalkBinding: HotkeyBinding

    var handsFreeEnabled: Bool {
        didSet { persist() }
    }

    private(set) var handsFreeKey: PushToTalkKey
    private(set) var handsFreeBinding: HotkeyBinding

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
        static let pushToTalkBinding = "pushToTalkBinding"
        static let handsFreeBinding = "handsFreeBinding"
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
        let requestedPrimaryBinding = snapshot?.resolvedPushToTalkBinding
            ?? selection.pushToTalk.binding(gesture: .hold)
        let requestedHandsFreeBinding = snapshot?.resolvedHandsFreeBinding
            ?? selection.handsFree.binding(gesture: .toggle)
        let registry = HotkeyBindingRegistry(
            pushToTalk: requestedPrimaryBinding,
            handsFree: requestedHandsFreeBinding
        )
        pushToTalkBinding = registry.pushToTalk
        handsFreeBinding = registry.handsFree
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
        let requestedLanguage = snapshot?.resolvedTranscriptionLanguage
            ?? TranscriptionLanguageOption(
                rawValue: defaults.string(forKey: Keys.transcriptionLanguage) ?? ""
            )
            ?? .systemDefault
        transcriptionLanguage = requestedLanguage
        // Apple by default: no download, no dependency, live text while speaking.
        let requestedEngine = snapshot?.engine
            ?? SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "")
            ?? .apple
        engine = resolvedEngineChoice(
            preferred: requestedEngine,
            language: requestedLanguage.selection
        )
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
            Keys.pushToTalkBinding,
            Keys.handsFreeBinding,
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
            ),
            pushToTalkBinding: defaults.data(forKey: Keys.pushToTalkBinding)
                .flatMap { try? JSONDecoder().decode(HotkeyBinding.self, from: $0) },
            handsFreeBinding: defaults.data(forKey: Keys.handsFreeBinding)
                .flatMap { try? JSONDecoder().decode(HotkeyBinding.self, from: $0) }
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
                let registry = HotkeyBindingRegistry(
                    pushToTalk: snapshot.resolvedPushToTalkBinding,
                    handsFree: snapshot.resolvedHandsFreeBinding
                )
                settings.pushToTalkBinding = registry.pushToTalk
                settings.handsFreeBinding = registry.handsFree
                settings.handsFreeEnabled = snapshot.resolvedHandsFreeEnabled
                settings.microphoneSelection = snapshot.resolvedMicrophoneSelection
                settings.transcriptionLanguage = snapshot.resolvedTranscriptionLanguage
                settings.engine = resolvedEngineChoice(
                    preferred: snapshot.engine,
                    language: settings.transcriptionLanguage.selection
                )
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
                settings.persistBindingMirrors()
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

    @discardableResult
    func selectPushToTalkBinding(_ binding: HotkeyBinding) -> Bool {
        guard !HotkeyBindingValidator.validate(
            primary: binding,
            handsFree: handsFreeEnabled ? handsFreeBinding : nil
        ).contains(where: { $0.severity == .error }) else { return false }
        pushToTalkBinding = binding
        if let preset = PushToTalkKey.allCases.first(where: { $0.keyCode == binding.keyCode }) {
            pushToTalkKey = preset
        }
        persist()
        return true
    }

    @discardableResult
    func selectHandsFreeBinding(_ binding: HotkeyBinding) -> Bool {
        guard !HotkeyBindingValidator.validate(
            primary: pushToTalkBinding,
            handsFree: binding
        ).contains(where: { $0.severity == .error }) else { return false }
        handsFreeBinding = binding.withGesture(.toggle)
        if let preset = PushToTalkKey.allCases.first(where: { $0.keyCode == binding.keyCode }) {
            handsFreeKey = preset
        }
        persist()
        return true
    }

    func selectPushToTalkGesture(_ gesture: HotkeyGesture) {
        pushToTalkBinding = pushToTalkBinding.withGesture(gesture)
        persist()
    }

    func restoreHotkeyDefaults() {
        pushToTalkKey = .rightOption
        handsFreeKey = .rightCommand
        pushToTalkBinding = PushToTalkKey.rightOption.binding(gesture: .hold)
        handsFreeBinding = PushToTalkKey.rightCommand.binding(gesture: .toggle)
        handsFreeEnabled = false
        persist()
    }

    private func apply(_ selection: HotkeyBindingSelection) {
        isHydrating = true
        pushToTalkKey = selection.pushToTalk
        handsFreeKey = selection.handsFree
        pushToTalkBinding = selection.pushToTalk.binding(gesture: pushToTalkBinding.gesture)
        handsFreeBinding = selection.handsFree.binding(gesture: .toggle)
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
            transcriptionLanguage: transcriptionLanguage,
            pushToTalkBinding: pushToTalkBinding,
            handsFreeBinding: handsFreeBinding
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(snapshot.pushToTalkKey, forKey: Keys.pushToTalkKey)
        defaults.set(snapshot.resolvedHandsFreeEnabled, forKey: Keys.handsFreeEnabled)
        defaults.set(snapshot.resolvedHandsFreeKey.rawValue, forKey: Keys.handsFreeKey)
        persistBindingMirrors()
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

    private func persistBindingMirrors() {
        if let data = try? JSONEncoder().encode(pushToTalkBinding) {
            defaults.set(data, forKey: Keys.pushToTalkBinding)
        }
        if let data = try? JSONEncoder().encode(handsFreeBinding) {
            defaults.set(data, forKey: Keys.handsFreeBinding)
        }
    }
}
