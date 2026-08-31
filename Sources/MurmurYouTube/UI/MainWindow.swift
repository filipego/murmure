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
                Text("Murmure")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.railInk)
                Text("LOCAL VOICE DESK")
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
                            Text(candidate.title)
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
                    .accessibilityLabel(candidate.title)
                    .accessibilityAddTraits(section == candidate ? .isSelected : [])
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: DS.Space.tight) {
                HStack(spacing: DS.Space.tight) {
                    Circle()
                        .fill(controller.state.isActive ? DS.Color.record : DS.Color.success)
                        .frame(width: DS.Space.tight, height: DS.Space.tight)
                    Text(controller.state.isActive ? "Recording" : "Ready")
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.railInk)
                }
                Text(MurmureDataStore.usesExternalStorage
                    ? "Audio and history stay on the external drive"
                    : "External drive unavailable; using local fallback")
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
                Text(section.title)
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                Text(section == .home ? "A clear place for the words you just spoke." : sectionSubtitle)
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
        .accessibilityLabel(isListening ? "Stop recording" : (isFinishing ? "Transcribing" : "Start recording"))
        .accessibilityValue(recordingAccessibilityValue)
    }

    private var recordingAccessibilityValue: String {
        switch controller.state {
        case .idle: "Ready"
        case .starting: "Preparing microphone"
        case .listening: "Listening"
        case .finishing: "Transcribing locally"
        case .error(let message): "Needs attention: \(message)"
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
                Text(title)
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
    @State private var store = RunStore.shared
    @State private var recoverableStore = RecoverableRecordingStore.shared
    @State private var audioPlayer = HistoryAudioPlayer()
    @State private var retranscriptionCoordinator = RetranscriptionCoordinator()
    @State private var query = ""
    @State private var correctionRun: DictationRun?
    @State private var retranscriptionSource: RetranscriptionSource?

    private var filteredRuns: [DictationRun] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = store.runs.reversed()
        guard !trimmed.isEmpty else { return Array(source) }
        return source.filter { $0.text.localizedStandardContains(trimmed) }
    }

    private var groupedRuns: [(Date, [DictationRun])] {
        let groups = Dictionary(grouping: filteredRuns) { Calendar.current.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { date in (date, groups[date] ?? []) }
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
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.wide) {
                stats

                if !recoverableStore.recordings.isEmpty {
                    recoverableSection
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Recent dictation")
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Color.ink)
                    Spacer()
                    Text("LOCAL HISTORY")
                        .font(DS.Font.eyebrow)
                        .tracking(DS.Font.silkscreenTracking)
                        .foregroundStyle(DS.Color.inkSecondary)
                }

                SearchField(text: $query, placeholder: "Search your local history")

                if groupedRuns.isEmpty {
                    EmptyHomeState(hasHistory: !store.runs.isEmpty)
                } else {
                    LazyVStack(alignment: .leading, spacing: DS.Space.roomy) {
                        ForEach(groupedRuns, id: \.0) { date, runs in
                            VStack(alignment: .leading, spacing: DS.Space.snug) {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(DS.Font.eyebrow)
                                    .tracking(DS.Font.silkscreenTracking)
                                    .foregroundStyle(DS.Color.inkSecondary)
                                ForEach(runs) { run in
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
        .task { await recoverableStore.refresh() }
    }

    private var recoverableSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recoverable recordings")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                Spacer()
                Text("SAFE LOCALLY")
                    .font(DS.Font.eyebrow)
                    .tracking(DS.Font.silkscreenTracking)
                    .foregroundStyle(DS.Color.inkSecondary)
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
            Text(label.uppercased())
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
                    Text(run.engine)
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
                Text(run.text.isEmpty ? "(Nothing recognized)" : run.text)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let corrections = run.corrections, !corrections.isEmpty {
                    HStack(spacing: DS.Space.tight) {
                        Image(systemName: "wand.and.stars")
                        Text("\(corrections.reduce(0) { $0 + $1.count }) dictionary correction\(corrections.count == 1 ? "" : "s")")
                    }
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
                }

                if let correction = run.correction {
                    HStack(spacing: DS.Space.tight) {
                        Image(systemName: "checkmark.circle")
                        Text(HistoryRowStatus.correction(correction))
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
                    .help(isPlaying ? "Stop audio recording" : "Play audio recording")
                    .accessibilityLabel(isPlaying ? "Stop audio recording" : "Play audio recording")
                    .accessibilityHint("Plays the saved recording inside Murmure")

                    Button(action: onRetranscribe) {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: DS.Space.roomy, height: DS.Space.roomy)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .disabled(correctionDisabled)
                    .help(correctionDisabled ? "Finish the current dictation before retrying history" : "Retranscribe recording")
                    .accessibilityLabel("Retranscribe recording")
                    .accessibilityHint("Runs this saved audio through a local speech engine and shows a preview")
                }

                Button(action: onCorrect) {
                    Image(systemName: "pencil")
                        .frame(width: DS.Space.roomy, height: DS.Space.roomy)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Color.inkSecondary)
                .disabled(correctionDisabled)
                .help(correctionDisabled ? "Finish the current dictation before correcting history" : "Correct dictation")
                .accessibilityLabel("Correct dictation")
                .accessibilityHint("Opens an editor for this saved dictation")

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
                .help(didCopy ? "Copied" : "Copy transcription")
                .accessibilityLabel(didCopy ? "Copied transcription" : "Copy transcription")
                .accessibilityHint("Copies this dictation to the clipboard")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: DS.Space.roomy, height: DS.Space.roomy)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Color.inkSecondary)
                .help("Delete transcription")
                .accessibilityLabel("Delete transcription")
                .accessibilityHint("Removes this dictation from local history")
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
                Text(recording.failure?.message ?? "This recording is ready to retranscribe.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.tight) {
                    Image(systemName: "externaldrive.fill.badge.checkmark")
                    Text("Audio retained locally")
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
                .help(isPlaying ? "Stop recoverable recording" : "Play recoverable recording")
                .accessibilityLabel(isPlaying ? "Stop recoverable recording" : "Play recoverable recording")

                Button(action: onRetranscribe) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: DS.Space.roomy, height: DS.Space.roomy)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Color.inkSecondary)
                .disabled(actionsDisabled)
                .help(actionsDisabled ? "Finish the current dictation before recovery" : "Retranscribe recoverable recording")
                .accessibilityLabel("Retranscribe recoverable recording")
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
            Text(hasHistory ? "No matching dictation" : "Your local history starts here")
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            Text(hasHistory ? "Try another search term." : "Press Record or hold your push-to-talk key, then speak naturally.")
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
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
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
            Text(label)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            Text(detail)
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(DS.Space.wide)
    }
}
