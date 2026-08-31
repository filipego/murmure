import SwiftUI

struct RetranscriptionSheet: View {
    let source: RetranscriptionSource
    let coordinator: RetranscriptionCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var engine: SpeechEngineChoice
    @State private var preview: RetranscriptionPreview?
    @State private var isProcessing = false
    @State private var isSaving = false
    @State private var message: String?

    init(source: RetranscriptionSource, coordinator: RetranscriptionCoordinator) {
        self.source = source
        self.coordinator = coordinator
        _engine = State(initialValue: source.initialEngine)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.wide) {
                header
                sourceSection
                engineSection
                if let preview { candidateSection(preview) }
                if let message {
                    Text(L10n.text(message))
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
            .padding(DS.Space.panel)
        }
        .scrollContentBackground(.hidden)
        .background(DS.Color.canvas)
        .frame(width: DS.Size.correctionSheetWidth)
        .frame(minHeight: DS.Size.correctionSheetMinHeight)
        .interactiveDismissDisabled(isBusy)
        .onChange(of: engine) {
            coordinator.cancel()
            preview = nil
            message = nil
        }
        .onDisappear { coordinator.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Text(L10n.text("Retranscribe recording"))
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
            Text(L10n.text("Murmure runs the saved audio locally. Nothing is typed or saved until you review and confirm the result."))
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Text(source.sectionTitle)
                .font(DS.Font.eyebrow)
                .tracking(DS.Font.silkscreenTracking)
                .foregroundStyle(DS.Color.inkSecondary)
            Text(source.sourceDescription)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.base)
                .background(DS.Color.panel, in: .rect(cornerRadius: DS.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                }
        }
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Text(L10n.text("LOCAL ENGINE"))
                .font(DS.Font.eyebrow)
                .tracking(DS.Font.silkscreenTracking)
                .foregroundStyle(DS.Color.inkSecondary)
            Picker(L10n.text("Speech engine"), selection: $engine) {
                ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                    Text(L10n.text(choice.displayName)).tag(choice)
                }
            }
            .labelsHidden()
            .disabled(isBusy)
            Text(L10n.text(engine == .parakeet && !ParakeetModels.isDownloaded
                ? "Parakeet may download its free local model before the first retry."
                : "The recording and transcript stay on this Mac."))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
        }
        .padding(DS.Space.base)
        .background(DS.Color.well, in: .rect(cornerRadius: DS.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        }
    }

    private func candidateSection(_ preview: RetranscriptionPreview) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("NEW LOCAL TRANSCRIPT"))
                    .font(DS.Font.eyebrow)
                    .tracking(DS.Font.silkscreenTracking)
                    .foregroundStyle(DS.Color.inkSecondary)
                Spacer()
                Text("\(preview.processSeconds, format: .number.precision(.fractionLength(2)))s")
                    .font(DS.Font.counter)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            Text(preview.candidateText)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.base)
                .background(DS.Color.panel, in: .rect(cornerRadius: DS.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                }
            if let snippet = preview.appliedSnippet {
                Text(L10n.format("Snippet applied: %@", arguments: [snippet.trigger]))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: DS.Space.snug) {
            Spacer()
            Button(L10n.text("Cancel"), role: .cancel) {
                coordinator.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isBusy)

            if let preview {
                Button(source.confirmTitle) {
                    Task { await confirm(preview) }
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Color.ink)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
            } else {
                Button(isProcessing ? "Transcribing…" : "Retranscribe") {
                    Task { await makePreview() }
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Color.ink)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
            }
        }
    }

    private var isBusy: Bool { isProcessing || isSaving }

    private func makePreview() async {
        guard !isBusy else { return }
        isProcessing = true
        message = nil
        defer { isProcessing = false }
        do {
            preview = try await coordinator.preview(source: source, engine: engine)
        } catch {
            preview = nil
            message = error.localizedDescription
        }
    }

    private func confirm(_ preview: RetranscriptionPreview) async {
        guard !isBusy else { return }
        isSaving = true
        message = nil
        defer { isSaving = false }
        guard await coordinator.confirm(preview) else {
            message = "The change could not be saved. The original recording and history are unchanged; check that the data drive is available, then try again."
            return
        }
        dismiss()
    }
}

private extension RetranscriptionSource {
    var initialEngine: SpeechEngineChoice {
        switch self {
        case .history(let run):
            run.engine.localizedCaseInsensitiveContains("parakeet") ? .parakeet : .apple
        case .recoverable(let recording):
            recording.engine == .parakeet ? .parakeet : .apple
        }
    }

    var sectionTitle: String {
        switch self {
        case .history: "CURRENT HISTORY"
        case .recoverable: "RECOVERY STATUS"
        }
    }

    var sourceDescription: String {
        switch self {
        case .history(let run):
            run.text.isEmpty ? "(Nothing recognized)" : run.text
        case .recoverable(let recording):
            recording.failure?.message ?? "This local recording is ready to retry."
        }
    }

    var confirmTitle: String {
        switch self {
        case .history: "Replace history"
        case .recoverable: "Save to history"
        }
    }
}
