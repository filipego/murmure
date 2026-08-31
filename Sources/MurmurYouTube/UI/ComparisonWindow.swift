import SwiftUI

/// Live-updating store behind the comparison window.
///
/// The window replaced a generated HTML file opened in the browser. That approach needed a
/// `file://` URL, spawned a fresh tab on every open, and left stale tabs showing old data
/// with no way to tell which was current. A window owned by the app has none of those
/// problems: one instance, always live, nothing to refresh.
@MainActor
@Observable
final class RunStore {
    static let shared = RunStore()

    private(set) var runs: [DictationRun] = []

    // Disk hydration is kicked off after the first window is on screen. Loading an external
    // volume synchronously here can stall SwiftUI before it has anything to render.
    private init() {}

    func reload() {
        runs = RunLog.load()
    }

    /// Recordings grouped by comparison, newest first.
    var comparisons: [[DictationRun]] {
        Dictionary(grouping: runs.filter { $0.group != nil }, by: { $0.group! })
            .values
            .sorted { ($0.first?.date ?? .distantPast) > ($1.first?.date ?? .distantPast) }
    }

    var singles: [DictationRun] {
        runs.filter { $0.group == nil }.reversed()
    }
}

struct ComparisonWindow: View {
    @Bindable var controller: DictationController
    @State private var store = RunStore.shared
    @State private var settings = Settings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                recordBar

                if store.runs.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(store.comparisons.enumerated()), id: \.offset) { _, group in
                        ComparisonCard(runs: group)
                    }
                    ForEach(Array(store.singles.enumerated()), id: \.offset) { _, run in
                        SingleCard(run: run)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(.background)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Engine comparison"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Color.ink)
                Text(L10n.format(
                    store.runs.count == 1 ? "%d recording" : "%d recordings",
                    arguments: [store.runs.count]
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !store.runs.isEmpty {
                Button(L10n.text("Clear")) {
                    RunLog.clear()
                    store.reload()
                }
            }
        }
    }

    /// One button that records every engine at once — no hotkeys, and the results appear in
    /// this same window, so there's nowhere to go afterwards to read them.
    private var recordBar: some View {
        let isRecording = controller.state.isActive

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    if isRecording {
                        controller.stopButtonRecording()
                    } else {
                        controller.startButtonRecording()
                    }
                } label: {
                    Label(
                        L10n.text(isRecording ? "Stop" : "Record both"),
                        systemImage: isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? DS.Color.record : DS.Color.ink)
                .controlSize(.large)
                .disabled(!isRecording && !controller.canStartButtonRecording)
            }

            Text(controller.transcript.isEmpty
                ? L10n.text(statusLine(isRecording: isRecording))
                : statusLine(isRecording: isRecording))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private func statusLine(isRecording: Bool) -> String {
        if isRecording { return "Recording — click Stop when you're done talking." }
        if !controller.transcript.isEmpty { return controller.transcript }
        return "Click Record, talk, click Stop. Apple and Parakeet both hear the same local recording."
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "waveform")
                .font(.system(size: 30))
                .foregroundStyle(DS.Color.inkSecondary)
            Text(L10n.format(
                "Use %@, say a sentence, then finish the configured gesture.",
                arguments: [settings.pushToTalkBinding.label]
            ))
                .font(.system(size: 15, weight: .semibold))
            Text(L10n.text(settings.compareMode
                 ? "Both engines run on that one recording and appear here."
                 : "Turn on Compare mode in the menu bar to see both engines at once."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

private struct ComparisonCard: View {
    let runs: [DictationRun]

    /// Fastest first. The engines are *measured* sequentially, so arrival order reflects
    /// which ran first, not which is quicker — sorting by measured time is what makes the
    /// winner readable at a glance.
    private var ranked: [DictationRun] {
        runs.sorted { $0.processSeconds < $1.processSeconds }
    }

    /// How much faster the winner was, once both are in.
    private var margin: String? {
        guard runs.count > 1,
              let best = ranked.first,
              let worst = ranked.last,
              best.processSeconds > 0
        else { return nil }
        let ratio = worst.processSeconds / best.processSeconds
        let delta = worst.processSeconds - best.processSeconds
        guard delta > 0.005 else { return "tied" }
        return L10n.format(
            "%@ %.1f× faster · %.2fs ahead",
            arguments: [best.engine, ratio, delta]
        )
    }

    /// Case and punctuation are normalized away: Apple auto-punctuates and Parakeet
    /// doesn't, and that's a formatting difference, not a recognition error.
    private var verdict: (String, Color) {
        if Set(runs.map(\.text)).count == 1 { return ("identical", DS.Color.success) }
        let normalized = Set(runs.map {
            $0.text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        })
        return normalized.count == 1 ? ("same words", DS.Color.success) : ("words differ", DS.Color.warning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(runs.first.map {
                    L10n.format(
                        "%@ · held %@s",
                        arguments: [
                            $0.date.formatted(date: .omitted, time: .standard),
                            $0.audioSeconds.formatted(.number.precision(.fractionLength(1)))
                        ]
                    )
                } ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L10n.text(verdict.0))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(verdict.1.opacity(0.16), in: Capsule())
                    .foregroundStyle(verdict.1)

                // Deletes the whole group: every engine here transcribed one utterance, so
                // removing that utterance means removing all of its rows together.
                if let group = runs.first?.group {
                    Button {
                        withAnimation { RunLog.deleteGroup(group) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L10n.text("Delete this comparison"))
                }
            }
            if let margin {
                HStack(spacing: 5) {
                    Image(systemName: margin == "tied" ? "equal.circle.fill" : "bolt.fill")
                    Text(L10n.text(margin))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.Color.success)
            } else if runs.count == 1 {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("running second engine…"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()
            ForEach(Array(ranked.enumerated()), id: \.offset) { index, run in
                EngineRow(run: run, rank: index + 1, showRank: runs.count > 1)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct EngineRow: View {
    let run: DictationRun
    let rank: Int
    let showRank: Bool

    private var isWinner: Bool { showRank && rank == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.engine + (isWinner ? L10n.text(" · fastest") : ""))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background((isWinner ? DS.Color.success : DS.Color.inkSecondary).opacity(0.16), in: Capsule())
                    .foregroundStyle(isWinner ? DS.Color.success : DS.Color.inkSecondary)
                Spacer()
                Text("\(run.processSeconds, format: .number.precision(.fractionLength(2)))s")
                    .font(.system(size: isWinner ? 20 : 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isWinner ? DS.Color.success : DS.Color.ink)
            }
            Text(L10n.format(
                "%@× realtime · %d chars",
                arguments: [run.realtimeFactor.formatted(.number.precision(.fractionLength(0))), run.characters]
            ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(run.text.isEmpty ? L10n.text("(nothing recognized)") : run.text)
                .font(.callout)
                .foregroundStyle(run.text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

private struct SingleCard: View {
    let run: DictationRun

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(run.engine).font(.caption.weight(.semibold))
                Spacer()
                Text("\(run.processSeconds, format: .number.precision(.fractionLength(2)))s")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(run.text).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }
}
