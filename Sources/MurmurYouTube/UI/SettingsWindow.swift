import AVFoundation
import AppKit
import MurmurAudioCore
import MurmurPermissionCore
import MurmurUpdateCore
import SwiftUI
import UniformTypeIdentifiers

enum SettingsCategory: String, CaseIterable, Identifiable {
    case dictation
    case shortcuts
    case microphoneAndSounds
    case appearance
    case privacyAndStorage
    case advancedAndUpdates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dictation"
        case .shortcuts: "Shortcuts"
        case .microphoneAndSounds: "Microphone & sounds"
        case .appearance: "Appearance"
        case .privacyAndStorage: "Privacy & storage"
        case .advancedAndUpdates: "Advanced & updates"
        }
    }

    var systemImage: String {
        switch self {
        case .dictation: "waveform"
        case .shortcuts: "command"
        case .microphoneAndSounds: "mic"
        case .appearance: "paintbrush"
        case .privacyAndStorage: "lock.shield"
        case .advancedAndUpdates: "gearshape.2"
        }
    }
}

enum SettingsMicrophoneTestPolicy {
    static func shouldStop(
        from oldCategory: SettingsCategory,
        to newCategory: SettingsCategory
    ) -> Bool {
        oldCategory == .microphoneAndSounds && newCategory != .microphoneAndSounds
    }
}

/// Settings uses the same calm cards as Home. It can be shown as the standard Settings scene
/// or embedded as the Settings destination in the main hub.
struct SettingsWindow: View {
    @Bindable var controller: DictationController
    var updates: AppUpdateCoordinator?
    @State private var settings = Settings.shared
    @State private var appLanguage = AppLanguageStore.shared
    @State private var audioInputs = AudioInputStore.shared
    @State private var speechLanguages = SpeechLanguageCatalog.shared
    @State private var microphoneTest = MicrophoneTestCoordinator()
    @State private var foundationModelAvailability = FoundationModelAvailabilityStore()
    @State private var permissionRefresh = 0
    @State private var hotkeyCaptureTarget: HotkeyCaptureTarget?
    @State private var pendingRiskyHotkey: PendingHotkey?
    @State private var hotkeyMessage: String?
    @State private var diagnosticsPreview: DiagnosticsPreview?
    @State private var diagnosticsMessage: String?
    @State private var selectedCategory: SettingsCategory = .dictation

    @Environment(\.openWindow) private var openWindow

    init(controller: DictationController, updates: AppUpdateCoordinator? = nil) {
        self.controller = controller
        self.updates = updates
    }

    var body: some View {
        HStack(spacing: 0) {
            categoryRail
            Rectangle()
                .fill(DS.Color.seam)
                .frame(width: DS.Border.seam)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.wide) {
                    if selectedCategory == .appearance {
                        settingsCard(
                            title: "Display language",
                            detail:
                                "Changes Murmure’s menus, buttons, and instructions. It does not change the language you dictate."
                        ) {
                            Picker(L10n.text("Display language"), selection: $appLanguage.language)
                            {
                                ForEach(AppLanguage.allCases, id: \.self) { language in
                                    Text(language.nativeName).tag(language)
                                }
                            }
                            .pickerStyle(.segmented)
                            .id(appLanguage.language)
                        }
                    }

                    if selectedCategory == .shortcuts {
                        settingsCard(
                            title: "Push to talk",
                            detail:
                                "Use this shortcut anywhere to dictate. The Record button works regardless of what is focused."
                        ) {
                            shortcutRow(
                                title: "Dictation shortcut",
                                binding: settings.pushToTalkBinding,
                                target: .pushToTalk
                            )

                            Picker(
                                L10n.text("Gesture"),
                                selection: Binding(
                                    get: { settings.pushToTalkBinding.gesture },
                                    set: { gesture in
                                        settings.selectPushToTalkGesture(gesture)
                                        controller.reloadHotkey()
                                    }
                                )
                            ) {
                                ForEach(HotkeyGesture.allCases, id: \.self) { gesture in
                                    Text(L10n.text(gesture.displayName)).tag(gesture)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 300, alignment: .leading)
                            .id(appLanguage.language)

                            Divider()

                            Toggle(
                                L10n.text("Enable hands-free dictation"),
                                isOn: Binding(
                                    get: { settings.handsFreeEnabled },
                                    set: { enabled in
                                        settings.handsFreeEnabled = enabled
                                        controller.reloadHotkey()
                                    }
                                ))

                            shortcutRow(
                                title: "Hands-free shortcut",
                                binding: settings.handsFreeBinding,
                                target: .handsFree
                            )
                            .disabled(!settings.handsFreeEnabled)

                            Text(
                                L10n.text(
                                    "Press once to start. Press the same key or Enter to finish; Escape cancels."
                                )
                            )
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                            if let hotkeyMessage {
                                Text(L10n.text(hotkeyMessage))
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Color.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Button(L10n.text("Restore shortcut defaults")) {
                                settings.restoreHotkeyDefaults()
                                hotkeyMessage = nil
                                controller.reloadHotkey()
                            }
                            .buttonStyle(.link)
                        }

                        settingsCard(
                            title: "Command Mode",
                            detail:
                                "Select text in another app, hold the shortcut, speak an editing instruction, then review the local proposal before anything is replaced."
                        ) {
                            Toggle(
                                L10n.text("Enable local Command Mode"),
                                isOn: Binding(
                                    get: { settings.commandModeEnabled },
                                    set: { enabled in
                                        settings.commandModeEnabled = enabled
                                        controller.reloadHotkey()
                                    }
                                ))

                            HStack(spacing: DS.Space.snug) {
                                Text(L10n.text("Command Mode shortcut"))
                                    .font(DS.Font.body)
                                    .foregroundStyle(DS.Color.ink)
                                Spacer()
                                Button(L10n.text(settings.commandModeBinding.label)) {
                                    beginHotkeyCapture(.commandMode)
                                }
                                .buttonStyle(.bordered)
                            }
                            .disabled(!settings.commandModeEnabled)

                            Text(L10n.text(commandModeAvailabilityText))
                                .font(DS.Font.caption)
                                .foregroundStyle(
                                    commandModeIsAvailable
                                        ? DS.Color.inkSecondary
                                        : DS.Color.warning
                                )
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if selectedCategory == .dictation {
                        settingsCard(
                            title: "Transcription",
                            detail: settings.engine == .apple
                                ? "Apple transcribes on-device and streams text while you speak."
                                : "Parakeet transcribes on-device when you release the key."
                        ) {
                            Picker(L10n.text("Engine"), selection: engineBinding) {
                                ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                                    Text(L10n.text(choice.displayName)).tag(choice)
                                }
                            }
                            .pickerStyle(.segmented)
                            .id(appLanguage.language)

                            Picker(L10n.text("Language you speak"), selection: languageBinding) {
                                ForEach(TranscriptionLanguageOption.allCases, id: \.self) {
                                    option in
                                    Text(L10n.text(option.displayName)).tag(option)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 260, alignment: .leading)
                            .id(appLanguage.language)

                            Text(
                                L10n.text(
                                    "Automatic recognizes supported languages while you speak. Choose a language only when you want to give the speech engine a specific hint."
                                )
                            )
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                            Text(L10n.text(transcriptionLanguageStatus))
                                .font(DS.Font.caption)
                                .foregroundStyle(
                                    transcriptionLanguageIsError
                                        ? DS.Color.warning
                                        : DS.Color.inkSecondary
                                )
                                .fixedSize(horizontal: false, vertical: true)

                            Picker(
                                L10n.text("When should Murmure type?"),
                                selection: $settings.textInsertionTiming
                            ) {
                                Text(L10n.text("After I finish speaking"))
                                    .tag(TextInsertionTiming.afterSpeaking)
                                Text(L10n.text("While I’m speaking"))
                                    .tag(TextInsertionTiming.whileSpeaking)
                            }
                            .pickerStyle(.menu)
                            .frame(width: DS.Size.settingsTimingPickerWidth, alignment: .leading)

                            Text(L10n.text(liveTypingStatusText))
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Toggle(
                                L10n.text("Compare both local engines"), isOn: $settings.compareMode
                            )
                        }

                        settingsCard(
                            title: "Cleanup",
                            detail:
                                "Cleanup removes fillers and fixes punctuation before dictionary corrections run."
                        ) {
                            Toggle(
                                L10n.text("Clean up transcripts"), isOn: $settings.cleanupEnabled)
                            Toggle(
                                L10n.text("Smart cleanup (on-device AI)"), isOn: smartCleanupBinding
                            )
                            .disabled(!settings.cleanupEnabled || !smartCleanupSupported)
                            if let reason = smartCleanupUnavailableReason {
                                Text(L10n.text(reason))
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Color.inkSecondary)
                            }
                        }
                    }

                    if selectedCategory == .microphoneAndSounds {
                        settingsCard(
                            title: "Microphone",
                            detail:
                                "Choose a local input for dictation. System default follows macOS without changing it."
                        ) {
                            Picker(
                                L10n.text("Input"),
                                selection: Binding(
                                    get: { settings.microphoneSelection },
                                    set: { selection in
                                        microphoneTest.stop()
                                        controller.resumeHotkeyAfterModalInput()
                                        settings.microphoneSelection = selection
                                        audioInputs.refresh()
                                    }
                                )
                            ) {
                                Text(L10n.text("System default")).tag(
                                    MicrophoneSelection.systemDefault)
                                ForEach(audioInputs.devices) { device in
                                    Text(microphoneLabel(device)).tag(
                                        MicrophoneSelection.device(
                                            uniqueID: device.id,
                                            displayName: device.displayName
                                        ))
                                }
                                if selectedMicrophoneIsUnavailable {
                                    Text(
                                        L10n.format(
                                            "%@ (unavailable)",
                                            arguments: [settings.microphoneSelection.displayName]
                                        )
                                    )
                                    .tag(settings.microphoneSelection)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 260, alignment: .leading)
                            .disabled(microphoneTest.state.isBusy)

                            VUMeter(
                                level: microphoneTest.level,
                                isActive: microphoneTest.state.isBusy
                            )
                            .frame(height: DS.Size.microphoneTestMeterHeight)

                            HStack(spacing: DS.Space.snug) {
                                Button(
                                    L10n.text(
                                        microphoneTest.state.isBusy
                                            ? "Stop test" : "Test microphone")
                                ) {
                                    toggleMicrophoneTest()
                                }
                                .buttonStyle(.bordered)
                                .disabled(controller.state.isActive)

                                Text(L10n.text(microphoneStatusText))
                                    .font(DS.Font.caption)
                                    .foregroundStyle(
                                        microphoneStatusIsError
                                            ? DS.Color.warning
                                            : DS.Color.inkSecondary
                                    )
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        settingsCard(
                            title: "Sounds",
                            detail:
                                "Choose whether Murmure plays a cue when dictation starts and finishes."
                        ) {
                            Toggle(
                                L10n.text("Play start and finish sounds"),
                                isOn: $settings.soundEnabled)
                        }
                    }

                    if selectedCategory == .privacyAndStorage {
                        settingsCard(
                            title: "Permissions",
                            detail:
                                "Murmure needs Microphone to listen and Accessibility to detect the global key and insert text into the focused app."
                        ) {
                            permissionRow(
                                title: "Microphone",
                                granted: Permissions.hasMicrophone,
                                actionTitle: microphoneActionTitle,
                                action: requestMicrophoneAccess
                            )
                            permissionRow(
                                title: "Accessibility",
                                granted: Permissions.hasAccessibility,
                                action: Permissions.openAccessibilitySettings
                            )
                        }
                        .id(permissionRefresh)
                        // TCC changes are made in System Settings, so keep this card alive while the
                        // user is granting access and force a fresh read when the status changes.

                        StorageCard()

                        settingsCard(
                            title: "Private diagnostics",
                            detail:
                                "Create a private diagnostic report. Reports include configuration and permission states, never dictated text, history, snippets, dictionary entries, or file paths."
                        ) {
                            HStack(spacing: DS.Space.snug) {
                                Button(L10n.text("Preview diagnostics")) { previewDiagnostics() }
                                    .buttonStyle(.bordered)
                                Button(L10n.text("Copy diagnostics")) { copyDiagnostics() }
                                    .buttonStyle(.bordered)
                                Button(L10n.text("Export diagnostics…")) { exportDiagnostics() }
                                    .buttonStyle(.bordered)
                            }

                            if let diagnosticsMessage {
                                Text(L10n.text(diagnosticsMessage))
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Color.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if selectedCategory == .advancedAndUpdates {
                        settingsCard(
                            title: "Guided setup",
                            detail:
                                "Run the guided setup again to review permissions, shortcuts, microphone, and language behavior."
                        ) {
                            Button(L10n.text("Run setup again")) {
                                OnboardingState.shared.reset()
                                openWindow(id: "onboarding")
                            }
                            .buttonStyle(.bordered)
                        }

                        if let updates {
                            UpdateCard(coordinator: updates, canInstall: !controller.state.isActive)
                        }
                    }
                }
                .padding(DS.Space.panel)
            }
            .scrollContentBackground(.hidden)
            .id(selectedCategory)
        }
        .background(DS.Color.canvas)
        .task {
            foundationModelAvailability.loadIfNeeded()
            audioInputs.refresh()
            await speechLanguages.refresh()
            updates?.refreshStagedUpdate()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                permissionRefresh += 1
            }
        }
        .onDisappear {
            microphoneTest.stop()
            controller.resumeHotkeyAfterModalInput()
        }
        .onChange(of: selectedCategory) { oldCategory, newCategory in
            guard SettingsMicrophoneTestPolicy.shouldStop(from: oldCategory, to: newCategory)
            else { return }
            microphoneTest.stop()
            controller.resumeHotkeyAfterModalInput()
        }
        .sheet(
            item: $hotkeyCaptureTarget,
            onDismiss: {
                controller.resumeHotkeyAfterModalInput()
            }
        ) { target in
            ShortcutRecorderSheet(
                title: hotkeyRecorderTitle(target),
                gesture: hotkeyRecorderGesture(target),
                onCapture: { binding in
                    hotkeyCaptureTarget = nil
                    handleCapturedHotkey(binding, target: target)
                },
                onCancel: { hotkeyCaptureTarget = nil }
            )
        }
        .sheet(item: $diagnosticsPreview) { preview in
            DiagnosticsPreviewSheet(json: preview.json)
        }
        .alert(
            L10n.text("Use this shortcut?"),
            isPresented: Binding(
                get: { pendingRiskyHotkey != nil },
                set: { if !$0 { pendingRiskyHotkey = nil } }
            )
        ) {
            Button(L10n.text("Use shortcut")) {
                if let pendingRiskyHotkey {
                    applyHotkey(pendingRiskyHotkey.binding, target: pendingRiskyHotkey.target)
                }
                pendingRiskyHotkey = nil
            }
            Button(L10n.text("Cancel"), role: .cancel) { pendingRiskyHotkey = nil }
        } message: {
            Text(pendingRiskyHotkey?.message ?? "")
        }
    }

    private var categoryRail: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            ForEach(SettingsCategory.allCases) { category in
                Button {
                    withAnimation(DS.Motion.panel) { selectedCategory = category }
                } label: {
                    HStack(spacing: DS.Space.snug) {
                        Image(systemName: category.systemImage)
                            .frame(width: DS.Size.settingsCategoryIconWidth)
                        Text(L10n.text(category.title))
                            .font(DS.Font.bodyEmphasis)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(
                        selectedCategory == category ? DS.Color.ink : DS.Color.inkSecondary
                    )
                    .padding(.horizontal, DS.Space.snug)
                    .padding(.vertical, DS.Space.snug)
                    .background(
                        selectedCategory == category ? DS.Color.selection : .clear,
                        in: .rect(cornerRadius: DS.Radius.control)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text(category.title))
                .accessibilityAddTraits(selectedCategory == category ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.roomy)
        .frame(width: DS.Size.settingsCategoryRailWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Color.chassis)
    }

    @ViewBuilder
    private func shortcutRow(
        title: String,
        binding: HotkeyBinding,
        target: HotkeyCaptureTarget
    ) -> some View {
        HStack(spacing: DS.Space.snug) {
            Text(L10n.text(title))
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
            Spacer()
            Button(L10n.text(binding.label)) { beginHotkeyCapture(target) }
                .buttonStyle(.bordered)
            Menu(L10n.text("Presets")) {
                ForEach(PushToTalkKey.allCases, id: \.self) { preset in
                    Button(L10n.text(preset.displayName)) {
                        let gesture =
                            target == .pushToTalk
                            ? settings.pushToTalkBinding.gesture
                            : .toggle
                        handleCapturedHotkey(
                            preset.binding(gesture: gesture),
                            target: target
                        )
                    }
                }
            }
        }
    }

    private func beginHotkeyCapture(_ target: HotkeyCaptureTarget) {
        hotkeyMessage = nil
        controller.suspendHotkeyForModalInput()
        hotkeyCaptureTarget = target
    }

    private func handleCapturedHotkey(
        _ binding: HotkeyBinding,
        target: HotkeyCaptureTarget
    ) {
        let primary = target == .pushToTalk ? binding : settings.pushToTalkBinding
        let handsFree = target == .handsFree ? binding : settings.handsFreeBinding
        let commandMode = target == .commandMode ? binding : settings.commandModeBinding
        let issues = HotkeyBindingValidator.validate(
            primary: primary,
            handsFree: target == .handsFree || settings.handsFreeEnabled ? handsFree : nil,
            commandMode: target == .commandMode || settings.commandModeEnabled ? commandMode : nil
        )
        if let error = issues.first(where: { $0.severity == .error }) {
            hotkeyMessage = error.message
            return
        }
        if let warning = issues.first(where: { $0.severity == .warning }) {
            pendingRiskyHotkey = PendingHotkey(
                target: target,
                binding: binding,
                message: warning.message
            )
            return
        }
        applyHotkey(binding, target: target)
    }

    private func applyHotkey(_ binding: HotkeyBinding, target: HotkeyCaptureTarget) {
        let applied =
            switch target {
            case .pushToTalk: settings.selectPushToTalkBinding(binding)
            case .handsFree: settings.selectHandsFreeBinding(binding)
            case .commandMode: settings.selectCommandModeBinding(binding)
            }
        hotkeyMessage = applied ? nil : "That shortcut conflicts with another Murmure action."
        if applied { controller.reloadHotkey() }
    }

    private func hotkeyRecorderTitle(_ target: HotkeyCaptureTarget) -> String {
        switch target {
        case .pushToTalk: "Record dictation shortcut"
        case .handsFree: "Record hands-free shortcut"
        case .commandMode: "Record Command Mode shortcut"
        }
    }

    private func hotkeyRecorderGesture(_ target: HotkeyCaptureTarget) -> HotkeyGesture {
        switch target {
        case .pushToTalk: settings.pushToTalkBinding.gesture
        case .handsFree: .toggle
        case .commandMode: .hold
        }
    }

    private var commandModeIsAvailable: Bool {
        foundationModelAvailability.isAvailable
    }

    private var commandModeAvailabilityText: String {
        switch foundationModelAvailability.state {
        case .checking:
            return L10n.text("Checking Apple's on-device model availability…")
        case .available:
            return L10n.text(
                "Apple's on-device model is ready. Selected text and instructions are never stored or sent to a server."
            )
        case .unavailable(let reason):
            return L10n.format(
                "Local transformation unavailable: %@ There is no network fallback.",
                arguments: [reason]
            )
        }
    }

    private var transcriptionLanguageStatus: String {
        if settings.engine == .parakeet {
            return settings.transcriptionLanguage == .systemDefault
                ? L10n.text("Parakeet automatically recognizes 25 European languages on-device.")
                : L10n.format(
                    "Parakeet uses %@ as an on-device decoder hint.",
                    arguments: [L10n.text(settings.transcriptionLanguage.displayName)]
                )
        }

        guard let status = speechLanguages.status(for: settings.transcriptionLanguage) else {
            return L10n.text("Checking Apple's on-device language assets…")
        }
        guard let identifier = status.resolvedLocaleIdentifier else {
            return L10n.text(
                "Apple Speech does not support this language on this Mac. Nothing will fall back to English."
            )
        }
        let name = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        return status.isInstalled
            ? L10n.format("Apple Speech · %@ · On-device model installed.", arguments: [name])
            : L10n.format(
                "Apple Speech · %@ · The system downloads its on-device model once when first used.",
                arguments: [name]
            )
    }

    private var diagnosticsSnapshot: DiagnosticsSnapshot {
        let bundle = Bundle.main
        let version =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let recentOperationFailed = if case .error = controller.state { true } else { false }

        return DiagnosticsCollector.collect(
            from: DiagnosticsInput(
                appVersion: version,
                appBuild: build,
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: currentArchitecture,
                microphone: settings.microphoneSelection.displayName,
                engine: settings.engine.displayName,
                language: settings.transcriptionLanguage.displayName,
                modelState: diagnosticsModelState,
                microphonePermission: Permissions.hasMicrophone ? "Granted" : "Needs access",
                accessibilityPermission: Permissions.hasAccessibility ? "Granted" : "Needs access",
                storageState: MurmureDataStore.statusTitle,
                recentOperationFailed: recentOperationFailed
            ))
    }

    private var diagnosticsModelState: String {
        if settings.engine == .parakeet {
            return ParakeetModels.isDownloaded
                ? "Parakeet local model installed"
                : "Parakeet local model not installed"
        }
        guard let status = speechLanguages.status(for: settings.transcriptionLanguage) else {
            return "Apple on-device model state is being checked"
        }
        return status.isInstalled
            ? "Apple on-device model installed"
            : "Apple on-device model not installed"
    }

    private func encodedDiagnostics() throws -> Data {
        try DiagnosticsCollector.encoded(diagnosticsSnapshot)
    }

    private func previewDiagnostics() {
        do {
            let data = try encodedDiagnostics()
            diagnosticsPreview = DiagnosticsPreview(
                json: String(decoding: data, as: UTF8.self)
            )
            diagnosticsMessage = nil
        } catch {
            diagnosticsMessage = "The diagnostic report could not be prepared."
        }
    }

    private func copyDiagnostics() {
        do {
            let string = String(decoding: try encodedDiagnostics(), as: UTF8.self)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
            diagnosticsMessage = "Sanitized diagnostics copied."
        } catch {
            diagnosticsMessage = "The diagnostic report could not be copied."
        }
    }

    private func exportDiagnostics() {
        do {
            let data = try encodedDiagnostics()
            let panel = NSSavePanel()
            panel.title = "Export Sanitized Diagnostics"
            panel.nameFieldStringValue = "Murmure Diagnostics.json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            diagnosticsMessage = "Sanitized diagnostics exported."
        } catch {
            diagnosticsMessage = "The diagnostic report could not be exported."
        }
    }

    private var engineBinding: Binding<SpeechEngineChoice> {
        Binding(
            get: { settings.engine },
            set: { choice in
                if choice == .apple, settings.transcriptionLanguage == .systemDefault {
                    settings.transcriptionLanguage = .explicitSystemLanguage()
                }
                settings.engine = choice
            }
        )
    }

    private var languageBinding: Binding<TranscriptionLanguageOption> {
        Binding(
            get: { settings.transcriptionLanguage },
            set: { language in
                settings.transcriptionLanguage = language
                if language == .systemDefault {
                    settings.engine = .parakeet
                }
            }
        )
    }

    private var transcriptionLanguageIsError: Bool {
        settings.engine == .apple
            && speechLanguages.status(for: settings.transcriptionLanguage)?.isSupported == false
    }

    private var liveTypingIsAvailable: Bool {
        LiveTypingPolicy.isEnabled(
            timing: settings.textInsertionTiming,
            engine: resolvedEngineChoice(
                preferred: settings.engine,
                language: settings.transcriptionLanguage.selection
            ),
            compareMode: settings.compareMode
        )
    }

    private var liveTypingStatusText: String {
        LiveTypingStatusPolicy.textKey(
            timing: settings.textInsertionTiming,
            engine: resolvedEngineChoice(
                preferred: settings.engine,
                language: settings.transcriptionLanguage.selection
            ),
            compareMode: settings.compareMode
        )
    }

    private var smartCleanupSupported: Bool {
        foundationModelAvailability.supports(settings.transcriptionLanguage.cleanupProfile)
    }

    private var smartCleanupBinding: Binding<Bool> {
        Binding(
            get: { settings.smartCleanup && smartCleanupSupported },
            set: { settings.smartCleanup = $0 }
        )
    }

    private var smartCleanupUnavailableReason: String? {
        guard settings.cleanupEnabled else { return nil }
        if let reason = foundationModelAvailability.unavailableReason { return reason }
        if foundationModelAvailability.state == .checking {
            return "Checking Apple's on-device model availability…"
        }
        guard smartCleanupSupported else {
            return L10n.format(
                "Smart cleanup does not support %@; deterministic local cleanup will be used.",
                arguments: [L10n.text(settings.transcriptionLanguage.displayName)]
            )
        }
        return nil
    }

    private var selectedMicrophoneIsUnavailable: Bool {
        guard case .device(let uniqueID, _) = settings.microphoneSelection else { return false }
        return !audioInputs.devices.contains { $0.id == uniqueID }
    }

    private var microphoneStatusText: String {
        switch microphoneTest.state {
        case .idle:
            if let error = audioInputs.errorMessage { return error }
            switch audioInputs.resolution(for: settings.microphoneSelection) {
            case .selected(let device):
                return L10n.format(
                    "Using %@ · %@",
                    arguments: [device.displayName, L10n.text(device.transport.displayName)]
                )
            case .fallback(let requested, let device):
                return L10n.format(
                    "%@ is unavailable. Using %@ for now; your selection is preserved.",
                    arguments: [requested.displayName, device.displayName]
                )
            case .unavailable(let requested):
                return L10n.format(
                    "%@ is unavailable. Connect a microphone and try again.",
                    arguments: [requested.displayName]
                )
            }
        case .starting:
            return "Opening the selected microphone…"
        case .testing(let name):
            return L10n.format("Listening to %@. Test audio is not saved.", arguments: [name])
        case .error(let message):
            return message
        }
    }

    private var microphoneStatusIsError: Bool {
        if audioInputs.errorMessage != nil { return true }
        if case .error = microphoneTest.state { return true }
        if case .unavailable = audioInputs.resolution(for: settings.microphoneSelection) {
            return true
        }
        return false
    }

    private func microphoneLabel(_ device: AudioInputDevice) -> String {
        let defaultLabel = device.isSystemDefault ? " · Default" : ""
        return "\(device.displayName) · \(device.transport.displayName)\(defaultLabel)"
    }

    private func toggleMicrophoneTest() {
        if microphoneTest.state.isBusy {
            microphoneTest.stop()
            controller.resumeHotkeyAfterModalInput()
            return
        }

        controller.suspendHotkeyForModalInput()
        Task { @MainActor in
            await microphoneTest.start(selection: settings.microphoneSelection)
            if !microphoneTest.state.isBusy {
                controller.resumeHotkeyAfterModalInput()
            }
        }
    }

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Text(L10n.text(title))
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
            Text(L10n.text(detail))
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.panel, in: .rect(cornerRadius: DS.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        }
    }

    private var microphoneActionTitle: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            "Request access"
        default:
            "Open System Settings"
        }
    }

    private func requestMicrophoneAccess() {
        let authorization: MicrophoneAuthorization
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            authorization = .notDetermined
        case .authorized:
            authorization = .authorized
        case .denied:
            authorization = .denied
        case .restricted:
            authorization = .restricted
        @unknown default:
            authorization = .restricted
        }

        switch MicrophonePermissionFlow.action(for: authorization) {
        case .alreadyGranted:
            permissionRefresh += 1
        case .openSettings:
            Permissions.openMicrophoneSettings()
        case .requestAccess:
            Task { @MainActor in
                let granted = await Permissions.requestMicrophone()
                permissionRefresh += 1
                if !granted {
                    Permissions.openMicrophoneSettings()
                }
            }
        }
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        actionTitle: String = "Open System Settings",
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: DS.Space.snug) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? DS.Color.success : DS.Color.warning)
            Text(L10n.text(title))
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            Text(L10n.text(granted ? "Granted" : "Needs access"))
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
            Spacer()
            if !granted {
                Button(L10n.text(actionTitle), action: action)
                    .buttonStyle(.link)
            }
        }
    }
}

private var currentArchitecture: String {
    #if arch(arm64)
        "Apple Silicon (arm64)"
    #elseif arch(x86_64)
        "Intel (x86_64)"
    #else
        "Unknown"
    #endif
}

private struct DiagnosticsPreview: Identifiable {
    let id = UUID()
    let json: String
}

private struct DiagnosticsPreviewSheet: View {
    let json: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Text(L10n.text("Sanitized diagnostics"))
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
            Text(L10n.text("Review the exact JSON before sharing it."))
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
            ScrollView {
                Text(json)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DS.Space.base)
            .background(DS.Color.well, in: .rect(cornerRadius: DS.Radius.control))
            HStack {
                Spacer()
                Button(L10n.text("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.panel)
        .frame(width: DS.Size.diagnosticsWidth, height: DS.Size.diagnosticsHeight)
        .background(DS.Color.canvas)
    }
}

private enum HotkeyCaptureTarget: String, Identifiable {
    case pushToTalk
    case handsFree
    case commandMode

    var id: String { rawValue }
}

private struct PendingHotkey {
    let target: HotkeyCaptureTarget
    let binding: HotkeyBinding
    let message: String
}

private struct StorageCard: View {
    private var isReady: Bool {
        MurmureDataStore.usesExternalStorage && MurmureDataStore.externalDriveConnected
    }

    private var statusColor: Color {
        isReady ? DS.Color.success : DS.Color.warning
    }

    var body: some View {
        settingsCard(title: "Data storage", detail: localizedStatusDetail) {
            HStack(spacing: DS.Space.snug) {
                Image(
                    systemName: isReady
                        ? "externaldrive.fill.badge.checkmark"
                        : "externaldrive.badge.exclamationmark"
                )
                .foregroundStyle(statusColor)
                Text(localizedStatusTitle)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                Spacer()
                Button(L10n.text("Reveal data folder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([MurmureDataStore.rootURL])
                }
                .buttonStyle(.link)
                .accessibilityLabel(L10n.text("Reveal Murmure data folder"))
            }

            Text(L10n.format("Migration: %@", arguments: [localizedMigrationDetail]))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var localizedStatusTitle: String {
        L10n.text(MurmureDataStore.statusTitle)
    }

    private var localizedStatusDetail: String {
        if MurmureDataStore.usesExternalStorage && MurmureDataStore.externalDriveConnected {
            return L10n.format(
                "Audio, history, dictionary, and settings save to %@.",
                arguments: [MurmureDataStore.externalRootURL.path]
            )
        }
        if MurmureDataStore.usesExternalStorage {
            return L10n.format(
                "Murmure cannot reach %@. Reconnect it before recording new audio.",
                arguments: [MurmureDataStore.preferredVolumeURL.path]
            )
        }
        return L10n.format(
            "The external drive was unavailable at launch, so new data is temporarily in %@.",
            arguments: [MurmureDataStore.rootURL.path]
        )
    }

    private var localizedMigrationDetail: String {
        L10n.text(MurmureDataStore.migrationDetail)
    }

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Text(L10n.text(title))
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
            Text(L10n.text(detail))
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.panel, in: .rect(cornerRadius: DS.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        }
    }
}

enum UpdateStatusText {
    static func available(
        _ version: AppVersion,
        language: AppLanguage? = nil
    ) -> String {
        L10n.format(
            "Version %@ (%@) is ready to install.",
            language: language,
            arguments: [version.marketing, String(version.build)]
        )
    }
}

private struct UpdateCard: View {
    let coordinator: AppUpdateCoordinator
    let canInstall: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("Updates"))
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                Spacer()
                Text(
                    "v\(coordinator.currentVersion.marketing) (\(coordinator.currentVersion.build))"
                )
                .font(DS.Font.counter)
                .foregroundStyle(DS.Color.inkSecondary)
            }

            Text(L10n.text(statusText))
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DS.Space.snug) {
                Button(L10n.text("Check for updates")) {
                    Task { await coordinator.checkForUpdates() }
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.state == .checking || coordinator.state == .installing)
                .accessibilityLabel(L10n.text("Check GitHub Releases for updates"))
                .accessibilityHint(
                    L10n.text(
                        "Downloads and prepares a verified Murmure release when one is available"))

                if case .available = coordinator.state {
                    Button(L10n.text("Install and relaunch")) {
                        coordinator.installAvailableUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Color.ink)
                    .disabled(!canInstall)
                    .accessibilityLabel(L10n.text("Install and relaunch"))
                    .accessibilityHint(
                        L10n.text("Replaces the installed bundle with the verified GitHub release"))
                }
            }
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.panel, in: .rect(cornerRadius: DS.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        }
    }

    private var statusText: String {
        switch coordinator.state {
        case .idle:
            "Updates are staged locally under Application Support."
        case .checking:
            "Checking GitHub Releases and preparing any update…"
        case .upToDate:
            "Murmure is up to date."
        case .available(let manifest):
            UpdateStatusText.available(manifest.version)
        case .installing:
            "Installing and relaunching Murmure…"
        case .failed(let message):
            L10n.format("Update unavailable: %@", arguments: [message])
        }
    }
}
