import AppKit
import SwiftUI

@main
struct MurmurYouTubeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The main window. A `Window` rather than a `WindowGroup`: this app has one front
        // panel, and letting ⌘N spawn a second copy of a tape deck makes no sense.
        Window(L10n.text("Murmure"), id: "main") {
            AppLanguageRoot {
                MainSceneRoot(controller: delegate.controller, updates: delegate.updateCoordinator)
            }
        }
        .defaultSize(width: 860, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(L10n.text("Reveal Dictionary File")) {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
            }
        }

        Window(L10n.text("Set up Murmure"), id: "onboarding") {
            AppLanguageRoot { OnboardingWindow(controller: delegate.controller) }
        }
        .windowResizability(.contentSize)

        Window(L10n.text("Command Mode"), id: "command-mode") {
            AppLanguageRoot { CommandModeWindow(controller: delegate.controller.commandMode) }
        }
        .windowResizability(.contentSize)

        // Fully qualified: this app has its own `Settings` type, which otherwise shadows
        // SwiftUI's settings scene.
        SwiftUI.Settings {
            AppLanguageRoot {
                SettingsWindow(controller: delegate.controller, updates: delegate.updateCoordinator)
            }
        }

        // Secondary now: status and the hotkey while you're working in another app.
        MenuBarExtra {
            AppLanguageRoot { MenuContent(controller: delegate.controller) }
        } label: {
            Image(systemName: delegate.controller.state.isActive ? "waveform.circle.fill" : "waveform")
        }

        Window(L10n.text("Engine comparison"), id: "comparison") {
            AppLanguageRoot { ComparisonWindow(controller: delegate.controller) }
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    let updateCoordinator = AppUpdateCoordinator()
    private lazy var hudLifecycle = HUDLifecycle {
        HUDPanel(controller: self.controller)
    }
    private var stateObservation: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let issue = RuntimeCompatibilityPolicy.currentIssue {
            NSApp.setActivationPolicy(.regular)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L10n.text("This Murmure build is not compatible with this Mac")
            alert.informativeText = L10n.text(issue.message)
            alert.addButton(withTitle: L10n.text("Quit Murmure"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // A regular app now: dock icon, app menu, standard windows. The HUD is still a
        // non-activating panel, so dictating into another app never steals its focus — that
        // property belongs to the panel, not to the activation policy.
        NSApp.setActivationPolicy(.regular)

        if !controller.activate() {
            Permissions.promptForAccessibility()
            // The tap can only be created once the user grants Accessibility, and there's
            // no notification for that — poll until it takes.
            retryActivation()
        }

        Log.app.info("Murmure data storage: \(MurmureDataStore.rootURL.path, privacy: .public)")

        // External-volume reads are deliberately deferred. A removable APFS volume can
        // suspend its first open for an unbounded interval; none of that should delay the
        // first window or make the app look like it failed to launch.
        MurmureDataStore.beginDeferredMigration()
        Settings.beginDeferredHydration()
        DictionaryStore.shared.beginDeferredHydration()
        SnippetStore.shared.beginDeferredHydration()
        RunLog.beginDeferredHydration()
        RunLog.beginDeferredPendingRuleRecovery()
        Task {
            await RecordingSessionRuntime.coordinator.recoverPendingSessions()
            await RecoverableRecordingStore.shared.refresh()
        }

        // Parakeet's models take ~20s to load from disk, and that cost lands on whichever
        // dictation touches them first — so the first hold after every launch would stall
        // with the HUD showing nothing. Warm them in the background instead, but only when
        // they're actually going to be used and are already downloaded.
        let willUseParakeet = Settings.shared.compareMode || Settings.shared.engine == .parakeet
        if willUseParakeet, ParakeetModels.isDownloaded {
            Task.detached(priority: .utility) {
                _ = try? await ParakeetModels.shared.manager()
            }
        }

        // Every `make install` relaunches the app and drops its windows. Restoring the
        // window when it was open last time keeps it from vanishing on each rebuild.
        if UserDefaults.standard.bool(forKey: "comparisonWindowOpen") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                Self.showComparisonWindow()
            }
        }

        observeState()
        Log.app.info("Murmure ready — use \(Settings.shared.pushToTalkBinding.label) to dictate")
    }

    /// `murmuryt://clear` and `murmuryt://show`, used by the legacy HTML dashboard and
    /// as a scriptable way to raise the window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "murmuryt" {
            switch url.host {
            case "clear":
                RunLog.clear()
                RunStore.shared.reload()
            case "show":
                Self.showComparisonWindow()
            default:
                break
            }
        }
    }

    /// Raises the comparison window without needing SwiftUI's `openWindow` environment
    /// value — usable from the app delegate and from a URL handler.
    static func showComparisonWindow() {
        RunStore.shared.reload()
        if let existing = NSApp.windows.first(where: { $0.title == "Engine comparison" }) {
            existing.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        let isOpen = NSApp.windows.contains { $0.title == "Engine comparison" && $0.isVisible }
        UserDefaults.standard.set(isOpen, forKey: "comparisonWindowOpen")
        controller.deactivate()
    }

    /// Shows and hides the HUD in step with the controller's state.
    private func observeState() {
        withObservationTracking {
            _ = controller.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hudLifecycle.setActive(self.controller.state.isActive)
                self.observeState()
            }
        }
    }

    private func retryActivation() {
        Task { @MainActor in
            while !Permissions.hasAccessibility {
                try? await Task.sleep(for: .seconds(1))
            }
            controller.activate()
            Log.app.info("Accessibility granted — hotkey armed")
        }
    }
}

private struct MenuContent: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @Environment(\.openWindow) private var openWindow
    @State private var isPreloadingParakeet = false
    @State private var parakeetOnDisk = ParakeetModels.isDownloaded

    private var parakeetStatus: String {
        if isPreloadingParakeet { return "Loading Parakeet models…" }
        // Reflects what's actually on disk, not just what this menu instance has done.
        return parakeetOnDisk ? "Parakeet models installed ✓" : "Download Parakeet models…"
    }

    private func preloadParakeet() {
        guard !isPreloadingParakeet else { return }
        isPreloadingParakeet = true
        Task {
            do {
                _ = try await ParakeetModels.shared.manager()
                parakeetOnDisk = ParakeetModels.isDownloaded
            } catch {
                Log.speech.error("Parakeet preload failed: \(error.localizedDescription)")
            }
            isPreloadingParakeet = false
        }
    }

    var body: some View {
        Text(L10n.format("Use %@ to dictate", arguments: [settings.pushToTalkBinding.label]))

        Divider()

        Menu(L10n.text("Choose shortcut preset")) {
            ForEach(PushToTalkKey.allCases, id: \.self) { key in
                Button(L10n.text(key.displayName)) {
                settings.selectPushToTalkKey(key)
                controller.reloadHotkey()
                }
            }
        }

        Toggle(L10n.text("Compare mode (both engines)"), isOn: $settings.compareMode)

        if !settings.compareMode {
            Picker(L10n.text("Engine"), selection: $settings.engine) {
                ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                    Text(L10n.text(choice.displayName)).tag(choice)
                }
            }
        }

        Toggle(L10n.text("Clean up text"), isOn: $settings.cleanupEnabled)

        if settings.cleanupEnabled {
            Toggle(L10n.text("Smart cleanup (on-device AI)"), isOn: $settings.smartCleanup)
                .disabled(!FoundationModelFormatter.isAvailable)
            if let reason = FoundationModelFormatter.unavailableReason {
                Text(L10n.text(reason)).font(.caption)
            }
        }

        Toggle(L10n.text("Sound"), isOn: $settings.soundEnabled)

        Divider()

        Button(L10n.text("Show comparison window")) {
            RunStore.shared.reload()
            openWindow(id: "comparison")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("d")

        // Downloading ~470 MB on the first hold would look like a hang, so offer to do it
        // deliberately instead.
        if settings.engine == .parakeet {
            Button(L10n.text(parakeetStatus)) { preloadParakeet() }
                .disabled(isPreloadingParakeet || parakeetOnDisk)
        }

        if !Permissions.hasAccessibility {
            Button(L10n.text("Grant Accessibility…")) { Permissions.openAccessibilitySettings() }
        }
        if !Permissions.hasMicrophone {
            Button(L10n.text("Grant Microphone…")) { Permissions.openMicrophoneSettings() }
        }

        Button(L10n.text("Quit Murmure")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
