import AppKit
import AVFoundation
import MurmurPermissionCore
import SwiftUI

/// Settings uses the same calm cards as Home. It can be shown as the standard Settings scene
/// or embedded as the Settings destination in the main hub.
struct SettingsWindow: View {
    @Bindable var controller: DictationController
    var updates: AppUpdateCoordinator?
    @State private var settings = Settings.shared
    @State private var permissionRefresh = 0

    init(controller: DictationController, updates: AppUpdateCoordinator? = nil) {
        self.controller = controller
        self.updates = updates
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.wide) {
                settingsCard(title: "Push to talk", detail: "Hold this key anywhere to dictate. The Record button works regardless of what is focused.") {
                    Picker("Push-to-talk key", selection: Binding(
                        get: { settings.pushToTalkKey },
                        set: { key in
                            settings.selectPushToTalkKey(key)
                            controller.reloadHotkey()
                        }
                    )) {
                        ForEach(PushToTalkKey.allCases, id: \.self) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260, alignment: .leading)
                }

                settingsCard(title: "Transcription", detail: settings.engine == .apple
                    ? "Apple transcribes on-device and streams text while you speak."
                    : "Parakeet transcribes on-device when you release the key.") {
                    Picker("Engine", selection: $settings.engine) {
                        ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Compare both local engines", isOn: $settings.compareMode)
                    Toggle("Play start and finish sounds", isOn: $settings.soundEnabled)
                }

                settingsCard(title: "Cleanup", detail: "Cleanup removes fillers and fixes punctuation before dictionary corrections run.") {
                    Toggle("Clean up transcripts", isOn: $settings.cleanupEnabled)
                    Toggle("Smart cleanup (on-device AI)", isOn: $settings.smartCleanup)
                        .disabled(!settings.cleanupEnabled || !FoundationModelFormatter.isAvailable)
                    if let reason = FoundationModelFormatter.unavailableReason {
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
            updates?.refreshStagedUpdate()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                permissionRefresh += 1
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
