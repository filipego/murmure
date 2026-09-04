import AppKit
import MurmurDictionary
import SwiftUI

/// The main command center. Navigation stays in a quiet rail while Home keeps the action and
/// local history in view; Dictionary and Settings are first-class destinations rather than
/// separate tape-deck windows.
struct MainWindow: View {
    @Bindable var controller: DictationController
    @Bindable var updates: AppUpdateCoordinator

    @State private var section: HubSection = .home

    init(controller: DictationController, updates: AppUpdateCoordinator) {
        self.controller = controller
        self.updates = updates
    }

    var body: some View {
        HStack(spacing: 0) {
            navigationRail
            Rectangle()
                .fill(DS.Color.seam)
                .frame(width: DS.Border.seam)
            content
        }
        .background(DS.Color.canvas)
        .frame(minWidth: 720, minHeight: 520)
        .task { updates.checkForStagedUpdate() }
    }

    private var navigationRail: some View {
        VStack(alignment: .leading, spacing: DS.Space.wide) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text(L10n.text("Murmure"))
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.railInk)
                Text(L10n.text("LOCAL VOICE DESK"))
                    .font(DS.Font.eyebrow)
                    .tracking(DS.Font.silkscreenTracking)
                    .foregroundStyle(DS.Color.railInkSecondary)
            }

            VStack(alignment: .leading, spacing: DS.Space.tight) {
                ForEach(HubSection.allCases) { candidate in
                    Button {
                        withAnimation(DS.Motion.panel) { section = candidate }
                    } label: {
                        HStack(spacing: DS.Space.snug) {
                            Image(systemName: candidate.systemImage)
                                .frame(width: 18)
                            Text(L10n.text(candidate.title))
                                .font(DS.Font.bodyEmphasis)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(section == candidate ? DS.Color.rail : DS.Color.railInk)
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.snug)
                        .background(
                            section == candidate ? DS.Color.railInk : .clear,
                            in: .rect(cornerRadius: DS.Radius.control)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text(candidate.title))
                    .accessibilityAddTraits(section == candidate ? .isSelected : [])
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: DS.Space.tight) {
                HStack(spacing: DS.Space.tight) {
                    Circle()
                        .fill(controller.state.isActive ? DS.Color.record : DS.Color.success)
                        .frame(width: DS.Space.tight, height: DS.Space.tight)
                    Text(L10n.text(controller.state.isActive ? "Recording" : "Ready"))
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.railInk)
                }
                Text(L10n.text(MurmureDataStore.usesExternalStorage
                    ? "Audio and history stay on the external drive"
                    : "External drive unavailable; using local fallback"))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.railInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DS.Space.rail)
        .padding(.vertical, DS.Space.panel)
        .frame(width: 196, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Color.rail)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(DS.Color.seam)
                .frame(height: DS.Border.seam)
            Group {
                switch section {
                case .home:
                    HomePanel(controller: controller)
                case .dictionary:
                    DictionaryPanel()
                case .snippets:
                    SnippetPanel()
                case .settings:
                    SettingsWindow(controller: controller, updates: updates)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(DS.Color.canvas)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.base) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text(L10n.text(section.title))
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                Text(L10n.text(section == .home ? "A clear place for the words you just spoke." : sectionSubtitle))
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            Spacer()
            if section == .home {
                recordButton
            }
        }
        .padding(.horizontal, DS.Space.panel)
        .padding(.vertical, DS.Space.roomy)
    }

    private var sectionSubtitle: String {
        switch section {
        case .home: ""
        case .dictionary: "Teach Murmure the words that matter to you."
        case .snippets: "Create reusable text for phrases you say often."
        case .settings: "Keep the local workflow tuned to your desk."
        }
    }

    private var recordButton: some View {
        let isListening = controller.state == .starting || controller.state == .listening
        let isFinishing = controller.state == .finishing
        let isError = if case .error = controller.state { true } else { false }
        return PrimaryActionButton(
            title: isListening ? "Stop recording" : (isFinishing ? "Transcribing…" : (isError ? "Record again" : "Record")),
            systemImage: isListening ? "stop.fill" : (isFinishing ? "ellipsis" : "mic.fill"),
            isActive: isListening
        ) {
            if isListening {
                controller.stopButtonRecording()
            } else {
                controller.startButtonRecording()
            }
        }
        .keyboardShortcut(.space, modifiers: [])
        .disabled(isFinishing || (!isListening && !controller.canStartButtonRecording))
        .accessibilityLabel(L10n.text(isListening ? "Stop recording" : (isFinishing ? "Transcribing" : "Start recording")))
        .accessibilityValue(L10n.text(recordingAccessibilityValue))
    }

    private var recordingAccessibilityValue: String {
        switch controller.state {
        case .idle: "Ready"
        case .starting: "Preparing microphone"
        case .listening: "Listening"
        case .finishing: "Transcribing locally"
        case .error(let message): L10n.format("Needs attention: %@", arguments: [message])
        }
    }
}

/// Shared primary action chrome for the Home record action and Dictionary's Add entry action.
/// Explicitly coloring the icon and title avoids AppKit's accent-color inheritance that can
/// make a `Label`-based button unreadable on the light action surface.
struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.snug) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isActive ? .white : DS.Color.canvas)
                Text(L10n.text(title))
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(isActive ? .white : DS.Color.canvas)
            }
            .padding(.horizontal, DS.Space.roomy)
            .padding(.vertical, DS.Space.snug)
            .background(isActive ? DS.Color.record : DS.Color.ink, in: .rect(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(.plain)
    }
}

private struct HomePanel: View {
    @Bindable var controller: DictationController
    @State private var appLanguage = AppLanguageStore.shared
    @State private var store = RunStore.shared
    @State private var recoverableStore = RecoverableRecordingStore.shared
    @State private var audioPlayer = HistoryAudioPlayer()
    @State private var retranscriptionCoordinator = RetranscriptionCoordinator()
    @State private var query = ""
    @State private var correctionRun: DictationRun?
    @State private var retranscriptionSource: RetranscriptionSource?
    @State private var pendingRecoverableDeletion: RecoverableRecording?
    @State private var confirmDeleteAllRecoverable = false

    private var filteredRuns: [DictationRun] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = store.runs.reversed()
        guard !trimmed.isEmpty else { return Array(source) }
        return source.filter { $0.text.localizedStandardContains(trimmed) }
    }

    private var historyItems: [HistoryListItem] {
        HistoryListItems.make(fromNewestFirst: filteredRuns)
    }

    private var words: Int {
        store.runs.reduce(0) { $0 + $1.text.split { $0.isWhitespace || $0.isNewline }.count }
    }

    private var corrections: Int {
        store.runs.reduce(0) { partial, run in
            partial + (run.corrections?.reduce(0) { $0 + $1.count } ?? 0)
        }
    }

    var body: some View {
        let historyItems = historyItems
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.wide) {
                stats

                if !recoverableStore.recordings.isEmpty {
                    recoverableSection
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("Recent dictation"))
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Color.ink)
                    Spacer()
                    Text(L10n.text("LOCAL HISTORY"))
                        .font(DS.Font.eyebrow)
                        .tracking(DS.Font.silkscreenTracking)
                        .foregroundStyle(DS.Color.inkSecondary)
                }

                SearchField(text: $query, placeholder: "Search your local history")

                if historyItems.isEmpty {
                    EmptyHomeState(hasHistory: !store.runs.isEmpty)
                } else {
                    LazyVStack(alignment: .leading, spacing: DS.Space.snug) {
                        ForEach(historyItems) { item in
                            switch item {
                            case .day(let date, let isFirst):
                                Text(date.formatted(
                                    Date.FormatStyle(date: .abbreviated, time: .omitted)
                                        .locale(appLanguage.language.locale)
                                ))
                                    .font(DS.Font.eyebrow)
                                    .tracking(DS.Font.silkscreenTracking)
                                    .foregroundStyle(DS.Color.inkSecondary)
                                    .padding(
                                        .top,
                                        isFirst
                                            ? DS.Space.none
                                            : DS.Space.roomy - DS.Space.snug
                                    )
                            case .run(let run):
                                HistoryRow(
                                    run: run,
                                    correctionDisabled: controller.state.isActive,
                                    isPlaying: audioPlayer.state == .playing(run.id),
                                    playbackMessage: playbackMessage(for: run.id),
                                    onPlay: { play(run) },
                                    onRetranscribe: {
                                        openRetranscription(.history(run))
                                    },
                                    onCorrect: { openCorrection(run) },
                                    onDelete: {
                                        withAnimation(DS.Motion.panel) { RunLog.delete(run) }
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(DS.Space.panel)
        }
        .scrollContentBackground(.hidden)
        .sheet(item: $correctionRun, onDismiss: {
            controller.resumeHotkeyAfterModalInput()
        }) { run in
            CorrectionEditor(run: run, dictationController: controller)
        }
        .sheet(item: $retranscriptionSource, onDismiss: {
            retranscriptionCoordinator.cancel()
            controller.resumeHotkeyAfterModalInput()
        }) { source in
            RetranscriptionSheet(source: source, coordinator: retranscriptionCoordinator)
        }
        .task {
            await RunLog.applyRetention(Settings.shared.historyRetention)
            await recoverableStore.refresh()
        }
        .confirmationDialog(
            L10n.text("Delete recoverable recording?"),
            isPresented: Binding(
                get: { pendingRecoverableDeletion != nil },
                set: { if !$0 { pendingRecoverableDeletion = nil } }
            )
        ) {
            Button(L10n.text("Delete recording"), role: .destructive) {
                guard let recording = pendingRecoverableDeletion else { return }
                audioPlayer.stop()
                Task { _ = await recoverableStore.delete(id: recording.id) }
                pendingRecoverableDeletion = nil
            }
            Button(L10n.text("Cancel"), role: .cancel) { pendingRecoverableDeletion = nil }
        } message: {
            Text(L10n.text("This permanently deletes the saved audio. It does not change your Dictionary or Snippets."))
        }
        .confirmationDialog(
            L10n.text("Delete all recoverable recordings?"),
            isPresented: $confirmDeleteAllRecoverable
        ) {
            Button(L10n.text("Delete all recordings"), role: .destructive) {
                audioPlayer.stop()
                Task { _ = await recoverableStore.deleteAll() }
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("This permanently deletes every unfinished recording. Completed History, Dictionary, and Snippets stay unchanged."))
        }
    }

    private var recoverableSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("Recoverable recordings"))
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                Spacer()
                Text(L10n.text("SAFE LOCALLY"))
                    .font(DS.Font.eyebrow)
                    .tracking(DS.Font.silkscreenTracking)
                    .foregroundStyle(DS.Color.inkSecondary)
                Button(L10n.text("Delete all")) {
                    confirmDeleteAllRecoverable = true
                }
                .buttonStyle(.link)
                .disabled(controller.state.isActive)
            }
            ForEach(recoverableStore.recordings) { recording in
                RecoverableHistoryRow(
                    recording: recording,
                    actionsDisabled: controller.state.isActive,
                    isPlaying: audioPlayer.state == .playing(recording.id),
                    playbackMessage: playbackMessage(for: recording.id),
                    onPlay: {
                        audioPlayer.toggle(id: recording.id, url: recording.audioURL)
                    },
                    onRetranscribe: {
                        openRetranscription(.recoverable(recording))
                    },
                    onDelete: {
                        pendingRecoverableDeletion = recording
                    }
                )
            }
        }
    }

    private var stats: some View {
        HStack(spacing: DS.Space.snug) {
            LocalStat(label: "Sessions", value: "\(store.runs.count)")
            LocalStat(label: "Words", value: "\(words)")
            LocalStat(label: "Corrections", value: "\(corrections)")
            LocalStat(label: "Push to talk", value: Settings.shared.pushToTalkBinding.label)
        }
    }

    private func openCorrection(_ run: DictationRun) {
        guard !controller.state.isActive else { return }
        controller.suspendHotkeyForModalInput()
        correctionRun = run
    }

    private func play(_ run: DictationRun) {
        guard let audioFile = run.audioFile,
              let audioURL = AudioHistoryStore.url(for: audioFile) else { return }
        audioPlayer.toggle(id: run.id, url: audioURL)
    }

    private func openRetranscription(_ source: RetranscriptionSource) {
        guard !controller.state.isActive else { return }
        audioPlayer.stop()
        controller.suspendHotkeyForModalInput()
        retranscriptionSource = source
    }

    private func playbackMessage(for id: UUID) -> String? {
        guard case let .error(failedID, message) = audioPlayer.state,
              failedID == id else { return nil }
        return message
    }
}

private struct LocalStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Text(L10n.text(label).uppercased())
                .font(DS.Font.eyebrow)
                .tracking(DS.Font.silkscreenTracking)
                .foregroundStyle(DS.Color.inkSecondary)
            Text(value)
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.base)
        .background(DS.Color.panel, in: .rect(cornerRadius: DS.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        }
    }
}

private struct HistoryRow: View {
    let run: DictationRun
    let correctionDisabled: Bool
    let isPlaying: Bool
    let playbackMessage: String?
    let onPlay: () -> Void
    let onRetranscribe: () -> Void
    let onCorrect: () -> Void
    let onDelete: () -> Void

    @State private var didCopy = false
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.base) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                HStack(spacing: DS.Space.snug) {
                    Text(L10n.text(run.engine))
                        .font(DS.Font.eyebrow)
                        .foregroundStyle(DS.Color.inkSecondary)
                    Text(run.date, style: .time)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                    Spacer()
                    Text("\(run.processSeconds, format: .number.precision(.fractionLength(2)))s")
                        .font(DS.Font.counter)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                Text(run.text.isEmpty ? L10n.text("(Nothing recognized)") : run.text)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let corrections = run.corrections, !corrections.isEmpty {
                    HStack(spacing: DS.Space.tight) {
                        Image(systemName: "wand.and.stars")
                        let correctionCount = corrections.reduce(0) { $0 + $1.count }
                        Text(L10n.format(
                            correctionCount == 1 ? "%d dictionary correction" : "%d dictionary corrections",
                            arguments: [correctionCount]
                        ))
                    }
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
                }

                if let snippet = run.appliedSnippet {
                    HStack(spacing: DS.Space.tight) {
                        Image(systemName: "text.badge.checkmark")
                        Text(L10n.format("Snippet · %@", arguments: [snippet.trigger]))
                    }
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                }

                if let correction = run.correction {
                    HStack(spacing: DS.Space.tight) {
                        Image(systemName: "checkmark.circle")
                        Text(L10n.text(HistoryRowStatus.correction(correction)))
                    }
                    .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                }

                if let playbackMessage {
                    Text(playbackMessage)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
            }

            HStack(spacing: DS.Space.tight) {
                if let audioFile = run.audioFile,
                   AudioHistoryStore.url(for: audioFile) != nil {
                    Button(action: onPlay) {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .frame(width: DS.Space.roomy, height: DS.Space.roomy)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .disabled(correctionDisabled)
                    .help(L10n.text(isPlaying ? "Stop audio recording" : "Play audio recording"))
                    .accessibilityLabel(L10n.text(isPlaying ? "Stop audio recording" : "Play audio recording"))
                    .accessibilityHint(L10n.text("Plays the saved recording inside Murmure"))

                    Button(action: onRetranscribe) {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: DS.Space.roomy, height: DS.Space.roomy)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .disabled(correctionDisabled)
                    .help(L10n.text(correctionDisabled ? "Finish the current dictation before retrying history" : "Retranscribe recording"))
                    .accessibilityLabel(L10n.text("Retranscribe recording"))
                    .accessibilityHint(L10n.text("Runs this saved audio through a local speech engine and shows a preview"))
                }

                Button(action: onCorrect) {
                    Image(systemName: "pencil")
                        .frame(width: DS.Space.roomy, height: DS.Space.roomy)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Color.inkSecondary)
                .disabled(correctionDisabled)
                .help(L10n.text(correctionDisabled ? "Finish the current dictation before correcting history" : "Correct dictation"))
                .accessibilityLabel(L10n.text("Correct dictation"))
                .accessibilityHint(L10n.text("Opens an editor for this saved dictation"))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.text, forType: .string)
                    didCopy = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); didCopy = false }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .frame(width: DS.Space.roomy, height: DS.Space.roomy)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Color.inkSecondary)
                .help(L10n.text(didCopy ? "Copied" : "Copy transcription"))
                .accessibilityLabel(L10n.text(didCopy ? "Copied transcription" : "Copy transcription"))
                .accessibilityHint(L10n.text("Copies this dictation to the clipboard"))

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: DS.Space.roomy, height: DS.Space.roomy)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Color.inkSecondary)
                .help(L10n.text("Delete transcription"))
                .accessibilityLabel(L10n.text("Delete transcription"))
                .accessibilityHint(L10n.text("Removes this dictation from local history"))
            }
            .opacity(isHovering ? 1 : 0.55)
        }
        .padding(DS.Space.base)
        .background(isHovering ? DS.Color.hover : DS.Color.panel, in: .rect(cornerRadius: DS.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        }
        .onHover { isHovering = $0 }
    }

}

enum HistoryRowStatus {
    static func correction(_ correction: TranscriptCorrectionRecord) -> String {
        if correction.inputMethod == .retranscription { return "Retranscribed locally" }
        if correction.rememberedRule != nil { return "Correction saved and remembered" }
        if correction.pendingRule != nil { return "Correction saved; rule pending" }
        return "Correction saved"
    }
}

private struct RecoverableHistoryRow: View {
    let recording: RecoverableRecording
    let actionsDisabled: Bool
    let isPlaying: Bool
    let playbackMessage: String?
    let onPlay: () -> Void
    let onRetranscribe: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.base) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                HStack(spacing: DS.Space.snug) {
                    Text(recording.engine == .apple ? "Apple" : "Parakeet")
                        .font(DS.Font.eyebrow)
                        .foregroundStyle(DS.Color.inkSecondary)
                    Text(recording.releasedAt ?? recording.startedAt, style: .time)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                Text(L10n.text(recording.failure?.message ?? "This recording is ready to retranscribe."))
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.tight) {
                    Image(systemName: "externaldrive.fill.badge.checkmark")
                    Text(L10n.text("Audio retained locally"))
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                if let playbackMessage {
                    Text(playbackMessage)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: DS.Space.tight) {
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .frame(width: DS.Space.roomy, height: DS.Space.roomy)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Color.inkSecondary)
                .disabled(actionsDisabled)
                .help(L10n.text(isPlaying ? "Stop recoverable recording" : "Play recoverable recording"))
                .accessibilityLabel(L10n.text(isPlaying ? "Stop recoverable recording" : "Play recoverable recording"))

                Button(action: onRetranscribe) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: DS.Space.roomy, height: DS.Space.roomy)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Color.inkSecondary)
                .disabled(actionsDisabled)
                .help(L10n.text(actionsDisabled ? "Finish the current dictation before recovery" : "Retranscribe recoverable recording"))
                .accessibilityLabel(L10n.text("Retranscribe recoverable recording"))

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: DS.Space.roomy, height: DS.Space.roomy)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Color.inkSecondary)
                .disabled(actionsDisabled)
                .help(L10n.text("Delete recoverable recording"))
                .accessibilityLabel(L10n.text("Delete recoverable recording"))
            }
            .opacity(isHovering ? 1 : 0.55)
        }
        .padding(DS.Space.base)
        .background(isHovering ? DS.Color.hover : DS.Color.panel, in: .rect(cornerRadius: DS.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        }
        .onHover { isHovering = $0 }
    }
}

private struct EmptyHomeState: View {
    let hasHistory: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Image(systemName: hasHistory ? "magnifyingglass" : "mic")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(DS.Color.inkSecondary)
            Text(L10n.text(hasHistory ? "No matching dictation" : "Your local history starts here"))
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            Text(L10n.text(hasHistory ? "Try another search term." : "Press Record or hold your push-to-talk key, then speak naturally."))
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.wide)
        .background(DS.Color.panel, in: .rect(cornerRadius: DS.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DS.Color.inkSecondary)
            TextField(L10n.text(placeholder), text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Clear search"))
            }
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.panel, in: .rect(cornerRadius: DS.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        }
    }
}

struct EmptyPanel: View {
    let label: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Text(L10n.text(label))
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            Text(L10n.text(detail))
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(DS.Space.wide)
    }
}
