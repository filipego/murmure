import SwiftUI
import MurmurAudioCore

struct MainSceneRoot: View {
    @Bindable var controller: DictationController
    let updates: AppUpdateCoordinator

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainWindow(controller: controller, updates: updates)
            .task {
                if !OnboardingState.shared.isCompleted {
                    openWindow(id: "onboarding")
                }
            }
            .onChange(of: controller.commandMode.state) { _, state in
                switch state {
                case .recordingInstruction, .processing, .review, .failed:
                    openWindow(id: "command-mode")
                    NSApp.activate(ignoringOtherApps: true)
                case .idle:
                    break
                }
            }
    }
}

struct OnboardingWindow: View {
    @Bindable var controller: DictationController

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var onboarding = OnboardingState.shared
    @State private var appLanguage = AppLanguageStore.shared
    @State private var settings = Settings.shared
    @State private var audioInputs = AudioInputStore.shared
    @State private var microphoneTest = MicrophoneTestCoordinator()
    @State private var microphoneTested = false
    @State private var testDictationAcknowledged = false
    @State private var permissionRefresh = 0

    var body: some View {
        let _ = permissionRefresh
        VStack(alignment: .leading, spacing: DS.Space.wide) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: DS.Space.tight) {
                    Text(L10n.text("Set up Murmure"))
                        .font(DS.Font.display)
                        .foregroundStyle(DS.Color.ink)
                    Text(L10n.text("Local voice dictation, ready for this Mac."))
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                Spacer()
                Text(stepCounter)
                    .font(DS.Font.counter)
                    .foregroundStyle(DS.Color.inkSecondary)
            }

            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.roomy)
                    .background(DS.Color.panel, in: .rect(cornerRadius: DS.Radius.panel))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.panel)
                            .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                    }
            }

            HStack(spacing: DS.Space.snug) {
                if onboarding.step != .appLanguage && onboarding.step != .complete {
                    Button(L10n.text("Back")) { onboarding.back() }
                }
                Spacer()
                if onboarding.step == .complete {
                    Button(L10n.text("Finish setup")) {
                        onboarding.complete()
                        dismissWindow(id: "onboarding")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Color.ink)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(L10n.text("Continue")) { onboarding.advance(readiness: readiness) }
                        .buttonStyle(.borderedProminent)
                        .tint(DS.Color.ink)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!OnboardingPolicy.canAdvance(
                            from: onboarding.step,
                            readiness: readiness
                        ))
                }
            }
        }
        .padding(DS.Space.panel)
        .frame(width: DS.Size.onboardingWidth, height: DS.Size.onboardingHeight)
        .background(DS.Color.canvas)
        .task {
            audioInputs.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                permissionRefresh += 1
            }
        }
        .onDisappear {
            microphoneTest.stop()
            controller.resumeHotkeyAfterModalInput()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.wide) {
            Text(stepTitle)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)

            switch onboarding.step {
            case .appLanguage:
                explanation("Choose the language Murmure uses for buttons, options, and instructions. You can change it later in Settings.")
                Picker(L10n.text("App language"), selection: $appLanguage.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
            case .privacy:
                explanation(
                    "Everything you dictate is processed on this Mac. Audio, history, snippets, and your dictionary stay in Murmure's local data folder. Only model downloads and update checks use the network."
                )
            case .microphonePermission:
                explanation("Microphone access lets Murmure hear a recording. macOS controls this permission.")
                readinessRow("Microphone", ready: Permissions.hasMicrophone)
                Button(L10n.text(Permissions.hasMicrophone ? "Microphone access granted" : "Request microphone access")) {
                    Task {
                        if !(await Permissions.requestMicrophone()) {
                            Permissions.openMicrophoneSettings()
                        }
                        permissionRefresh += 1
                    }
                }
                .disabled(Permissions.hasMicrophone)
            case .accessibilityPermission:
                explanation("Accessibility lets the global shortcut work and inserts finished text into the app you were using.")
                readinessRow("Accessibility", ready: Permissions.hasAccessibility)
                Button(L10n.text(Permissions.hasAccessibility ? "Accessibility granted" : "Open Accessibility Settings")) {
                    Permissions.promptForAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                .disabled(Permissions.hasAccessibility)
            case .shortcut:
                explanation("Choose a comfortable shortcut. You can record any modified key combination later in Settings.")
                Picker(L10n.text("Shortcut"), selection: Binding(
                    get: { settings.pushToTalkKey },
                    set: { settings.selectPushToTalkKey($0); controller.reloadHotkey() }
                )) {
                    ForEach(PushToTalkKey.allCases, id: \.self) { Text(L10n.text($0.displayName)).tag($0) }
                }
                Picker(L10n.text("Gesture"), selection: Binding(
                    get: { settings.pushToTalkBinding.gesture },
                    set: { settings.selectPushToTalkGesture($0); controller.reloadHotkey() }
                )) {
                    ForEach(HotkeyGesture.allCases, id: \.self) { Text(L10n.text($0.displayName)).tag($0) }
                }
            case .microphoneTest:
                explanation("Pick an input, start the meter, speak briefly, then stop the test.")
                Picker(L10n.text("Input"), selection: $settings.microphoneSelection) {
                    Text(L10n.text("System default")).tag(MicrophoneSelection.systemDefault)
                    ForEach(audioInputs.devices) { device in
                        Text(device.displayName).tag(MicrophoneSelection.device(
                            uniqueID: device.id,
                            displayName: device.displayName
                        ))
                    }
                }
                VUMeter(level: microphoneTest.level, isActive: microphoneTest.state.isBusy)
                    .frame(height: DS.Size.microphoneTestMeterHeight)
                Button(L10n.text(microphoneTest.state.isBusy ? "Stop microphone test" : "Start microphone test")) {
                    toggleMicrophoneTest()
                }
                readinessRow("Microphone test", ready: microphoneTested)
            case .language:
                explanation("Automatic recognizes any of Parakeet's 25 supported European languages. Choose one language when you want an explicit decoder hint.")
                Picker(L10n.text("Engine"), selection: onboardingEngineBinding) {
                    ForEach(SpeechEngineChoice.allCases, id: \.self) { Text(L10n.text($0.displayName)).tag($0) }
                }
                Picker(L10n.text("Language"), selection: onboardingLanguageBinding) {
                    ForEach(TranscriptionLanguageOption.allCases, id: \.self) { Text(L10n.text($0.displayName)).tag($0) }
                }
            case .testDictation:
                explanation("Record one short sentence. It will be saved to local history; this setup window does not contain a text field to paste into.")
                Button(testDictationButtonTitle) {
                    if controller.state == .starting || controller.state == .listening {
                        controller.stopButtonRecording()
                    } else {
                        controller.startButtonRecording()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Color.ink)
                .disabled(controller.state == .finishing)
                Toggle(L10n.text("I completed the test dictation"), isOn: $testDictationAcknowledged)
            case .complete:
                explanation("Murmure is ready. Hold your shortcut in any app, speak, then finish the selected gesture. You can rerun setup from Settings at any time.")
                readinessRow("Microphone", ready: Permissions.hasMicrophone)
                readinessRow("Accessibility", ready: Permissions.hasAccessibility)
            }
        }
    }

    private var readiness: OnboardingReadiness {
        OnboardingReadiness(
            microphoneGranted: Permissions.hasMicrophone,
            accessibilityGranted: Permissions.hasAccessibility,
            microphoneTested: microphoneTested,
            testDictationAcknowledged: testDictationAcknowledged
        )
    }

    private var onboardingEngineBinding: Binding<SpeechEngineChoice> {
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

    private var onboardingLanguageBinding: Binding<TranscriptionLanguageOption> {
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

    private var testDictationButtonTitle: String {
        switch controller.state {
        case .starting, .listening:
            L10n.text("Finish test dictation")
        case .finishing:
            L10n.text("Finishing test dictation…")
        case .idle, .error:
            L10n.text("Start test dictation")
        }
    }

    private var stepCounter: String {
        let index = OnboardingStep.allCases.firstIndex(of: onboarding.step) ?? 0
        return "\(index + 1) / \(OnboardingStep.allCases.count)"
    }

    private var stepTitle: String {
        switch onboarding.step {
        case .appLanguage: L10n.text("Choose app language")
        case .privacy: L10n.text("Private by design")
        case .microphonePermission: L10n.text("Allow microphone access")
        case .accessibilityPermission: L10n.text("Allow the global shortcut")
        case .shortcut: L10n.text("Choose your shortcut")
        case .microphoneTest: L10n.text("Test your microphone")
        case .language: L10n.text("Choose language behavior")
        case .testDictation: L10n.text("Try one local dictation")
        case .complete: L10n.text("Setup complete")
        }
    }

    private func explanation(_ text: String) -> some View {
        Text(L10n.text(text))
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func readinessRow(_ title: String, ready: Bool) -> some View {
        Label(
            L10n.format(
                ready ? "%@ ready" : "%@ needs attention",
                arguments: [L10n.text(title)]
            ),
            systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
            .font(DS.Font.bodyEmphasis)
            .foregroundStyle(ready ? DS.Color.success : DS.Color.warning)
    }

    private func toggleMicrophoneTest() {
        if microphoneTest.state.isBusy {
            microphoneTest.stop()
            microphoneTested = true
            controller.resumeHotkeyAfterModalInput()
            return
        }
        controller.suspendHotkeyForModalInput()
        Task {
            await microphoneTest.start(selection: settings.microphoneSelection)
            if !microphoneTest.state.isBusy { controller.resumeHotkeyAfterModalInput() }
        }
    }
}
