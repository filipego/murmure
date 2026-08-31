import AppKit
import AVFoundation
import MurmurAudioCore
import MurmurPermissionCore
import SwiftUI

/// Settings uses the same calm cards as Home. It can be shown as the standard Settings scene
/// or embedded as the Settings destination in the main hub.
struct SettingsWindow: View {
    @Bindable var controller: DictationController
    var updates: AppUpdateCoordinator?
    @State private var settings = Settings.shared
    @State private var audioInputs = AudioInputStore.shared
    @State private var speechLanguages = SpeechLanguageCatalog.shared
    @State private var microphoneTest = MicrophoneTestCoordinator()
    @State private var permissionRefresh = 0
    @State private var hotkeyCaptureTarget: HotkeyCaptureTarget?
    @State private var pendingRiskyHotkey: PendingHotkey?
    @State private var hotkeyMessage: String?

    init(controller: DictationController, updates: AppUpdateCoordinator? = nil) {
        self.controller = controller
        self.updates = updates
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.wide) {
                settingsCard(title: "Push to talk", detail: "Use this shortcut anywhere to dictate. The Record button works regardless of what is focused.") {
                    shortcutRow(
                        title: "Dictation shortcut",
                        binding: settings.pushToTalkBinding,
                        target: .pushToTalk
                    )

                    Picker("Gesture", selection: Binding(
                        get: { settings.pushToTalkBinding.gesture },
                        set: { gesture in
                            settings.selectPushToTalkGesture(gesture)
                            controller.reloadHotkey()
                        }
                    )) {
                        ForEach(HotkeyGesture.allCases, id: \.self) { gesture in
                            Text(gesture.displayName).tag(gesture)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 300, alignment: .leading)

                    Divider()

                    Toggle("Enable hands-free dictation", isOn: Binding(
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

                    Text("Press once to start. Press the same key or Enter to finish; Escape cancels.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let hotkeyMessage {
                        Text(hotkeyMessage)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button("Restore shortcut defaults") {
                        settings.restoreHotkeyDefaults()
                        hotkeyMessage = nil
                        controller.reloadHotkey()
                    }
                    .buttonStyle(.link)
                }

                settingsCard(title: "Transcription", detail: settings.engine == .apple
                    ? "Apple transcribes on-device and streams text while you speak."
                    : "Parakeet transcribes on-device when you release the key.") {
                    Picker("Engine", selection: engineBinding) {
                        ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Language", selection: languageBinding) {
                        ForEach(TranscriptionLanguageOption.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260, alignment: .leading)

                    Text(transcriptionLanguageStatus)
                        .font(DS.Font.caption)
                        .foregroundStyle(transcriptionLanguageIsError
                            ? DS.Color.warning
                            : DS.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Compare both local engines", isOn: $settings.compareMode)
                    Toggle("Play start and finish sounds", isOn: $settings.soundEnabled)
                }

                settingsCard(
                    title: "Microphone",
                    detail: "Choose a local input for dictation. System default follows macOS without changing it."
                ) {
                    Picker("Input", selection: Binding(
                        get: { settings.microphoneSelection },
                        set: { selection in
                            microphoneTest.stop()
                            controller.resumeHotkeyAfterModalInput()
                            settings.microphoneSelection = selection
                            audioInputs.refresh()
                        }
                    )) {
                        Text("System default").tag(MicrophoneSelection.systemDefault)
                        ForEach(audioInputs.devices) { device in
                            Text(microphoneLabel(device)).tag(MicrophoneSelection.device(
                                uniqueID: device.id,
                                displayName: device.displayName
                            ))
                        }
                        if selectedMicrophoneIsUnavailable {
                            Text("\(settings.microphoneSelection.displayName) (unavailable)")
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
                        Button(microphoneTest.state.isBusy ? "Stop test" : "Test microphone") {
                            toggleMicrophoneTest()
                        }
                        .buttonStyle(.bordered)
                        .disabled(controller.state.isActive)

                        Text(microphoneStatusText)
                            .font(DS.Font.caption)
                            .foregroundStyle(microphoneStatusIsError
                                ? DS.Color.warning
                                : DS.Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                settingsCard(title: "Cleanup", detail: "Cleanup removes fillers and fixes punctuation before dictionary corrections run.") {
                    Toggle("Clean up transcripts", isOn: $settings.cleanupEnabled)
                    Toggle("Smart cleanup (on-device AI)", isOn: smartCleanupBinding)
                        .disabled(!settings.cleanupEnabled || !smartCleanupSupported)
                    if let reason = smartCleanupUnavailableReason {
                        Text(reason)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.inkSecondary)
                    }
                }

                settingsCard(title: "Permissions", detail: "Murmure needs Microphone to listen and Accessibility to detect the global key and insert text into the focused app.") {
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
                // TCC changes are made in System Settings, so keep this card alive while the
                // user is granting access and force a fresh read when the status changes.
                .id(permissionRefresh)

                StorageCard()

                if let updates {
                    UpdateCard(coordinator: updates, canInstall: !controller.state.isActive)
                }
            }
            .padding(DS.Space.panel)
        }
        .background(DS.Color.canvas)
        .task {
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
        .sheet(item: $hotkeyCaptureTarget, onDismiss: {
            controller.resumeHotkeyAfterModalInput()
        }) { target in
            ShortcutRecorderSheet(
                title: target == .pushToTalk
                    ? "Record dictation shortcut"
                    : "Record hands-free shortcut",
                gesture: target == .pushToTalk
                    ? settings.pushToTalkBinding.gesture
                    : .toggle,
                onCapture: { binding in
                    hotkeyCaptureTarget = nil
                    handleCapturedHotkey(binding, target: target)
                },
                onCancel: { hotkeyCaptureTarget = nil }
            )
        }
        .alert("Use this shortcut?", isPresented: Binding(
            get: { pendingRiskyHotkey != nil },
            set: { if !$0 { pendingRiskyHotkey = nil } }
        )) {
            Button("Use shortcut") {
                if let pendingRiskyHotkey {
                    applyHotkey(pendingRiskyHotkey.binding, target: pendingRiskyHotkey.target)
                }
                pendingRiskyHotkey = nil
            }
            Button("Cancel", role: .cancel) { pendingRiskyHotkey = nil }
        } message: {
            Text(pendingRiskyHotkey?.message ?? "")
        }
    }

    @ViewBuilder
    private func shortcutRow(
        title: String,
        binding: HotkeyBinding,
        target: HotkeyCaptureTarget
    ) -> some View {
        HStack(spacing: DS.Space.snug) {
            Text(title)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
            Spacer()
            Button(binding.label) { beginHotkeyCapture(target) }
                .buttonStyle(.bordered)
            Menu("Presets") {
                ForEach(PushToTalkKey.allCases, id: \.self) { preset in
                    Button(preset.displayName) {
                        let gesture = target == .pushToTalk
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
        let issues = HotkeyBindingValidator.validate(
            primary: primary,
            handsFree: target == .handsFree || settings.handsFreeEnabled ? handsFree : nil
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
        let applied = switch target {
        case .pushToTalk: settings.selectPushToTalkBinding(binding)
        case .handsFree: settings.selectHandsFreeBinding(binding)
        }
        hotkeyMessage = applied ? nil : "That shortcut conflicts with another Murmure action."
        if applied { controller.reloadHotkey() }
    }

    private var transcriptionLanguageStatus: String {
        if settings.engine == .parakeet {
            return settings.transcriptionLanguage == .systemDefault
                ? "Parakeet automatically recognizes 25 European languages on-device."
                : "Parakeet uses \(settings.transcriptionLanguage.displayName) as an on-device decoder hint."
        }

        guard let status = speechLanguages.status(for: settings.transcriptionLanguage) else {
            return "Checking Apple's on-device language assets…"
        }
        guard let identifier = status.resolvedLocaleIdentifier else {
            return "Apple Speech does not support this language on this Mac. Nothing will fall back to English."
        }
        let name = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        return status.isInstalled
            ? "Apple Speech · \(name) · On-device model installed."
            : "Apple Speech · \(name) · The system downloads its on-device model once when first used."
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

    private var smartCleanupSupported: Bool {
        FoundationModelFormatter.supports(settings.transcriptionLanguage.cleanupProfile)
    }

    private var smartCleanupBinding: Binding<Bool> {
        Binding(
            get: { settings.smartCleanup && smartCleanupSupported },
            set: { settings.smartCleanup = $0 }
        )
    }

    private var smartCleanupUnavailableReason: String? {
        guard settings.cleanupEnabled else { return nil }
        if let reason = FoundationModelFormatter.unavailableReason { return reason }
        guard smartCleanupSupported else {
            return "Smart cleanup does not support \(settings.transcriptionLanguage.displayName); deterministic local cleanup will be used."
        }
        return nil
    }

    private var selectedMicrophoneIsUnavailable: Bool {
        guard case let .device(uniqueID, _) = settings.microphoneSelection else { return false }
        return !audioInputs.devices.contains { $0.id == uniqueID }
    }

    private var microphoneStatusText: String {
        switch microphoneTest.state {
        case .idle:
            if let error = audioInputs.errorMessage { return error }
            return audioInputs.resolution(for: settings.microphoneSelection).statusText
        case .starting:
            return "Opening the selected microphone…"
        case let .testing(name):
            return "Listening to \(name). Test audio is not saved."
        case let .error(message):
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
            Text(title)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
            Text(detail)
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
            Text(title)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            Text(granted ? "Granted" : "Needs access")
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
            Spacer()
            if !granted {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
            }
        }
    }
}

private enum HotkeyCaptureTarget: String, Identifiable {
    case pushToTalk
    case handsFree

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
        settingsCard(title: "Data storage", detail: MurmureDataStore.statusDetail) {
            HStack(spacing: DS.Space.snug) {
                Image(systemName: isReady ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.exclamationmark")
                    .foregroundStyle(statusColor)
                Text(MurmureDataStore.statusTitle)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                Spacer()
                Button("Reveal data folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([MurmureDataStore.rootURL])
                }
                .buttonStyle(.link)
                .accessibilityLabel("Reveal Murmure data folder")
            }

            Text("Migration: \(MurmureDataStore.migrationDetail)")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Text(title)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
            Text(detail)
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

private struct UpdateCard: View {
    let coordinator: AppUpdateCoordinator
    let canInstall: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack(alignment: .firstTextBaseline) {
                Text("Updates")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                Spacer()
                Text("v\(coordinator.currentVersion.marketing) (\(coordinator.currentVersion.build))")
                    .font(DS.Font.counter)
                    .foregroundStyle(DS.Color.inkSecondary)
            }

            Text(statusText)
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DS.Space.snug) {
                Button("Check for updates") {
                    Task { await coordinator.checkForUpdates() }
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.state == .checking || coordinator.state == .installing)
                .accessibilityLabel("Check GitHub Releases for updates")
                .accessibilityHint("Downloads and prepares a verified Murmure release when one is available")

                if case .available = coordinator.state {
                    Button("Install and relaunch") {
                        coordinator.installAvailableUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Color.ink)
                    .disabled(!canInstall)
                    .accessibilityLabel("Install and relaunch")
                    .accessibilityHint("Replaces the installed bundle with the verified GitHub release")
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
        case let .available(manifest):
            "Version \(manifest.version.marketing) (\(manifest.version.build)) is ready to install."
        case .installing:
            "Installing and relaunching Murmure…"
        case let .failed(message):
            "Update unavailable: \(message)"
        }
    }
}
