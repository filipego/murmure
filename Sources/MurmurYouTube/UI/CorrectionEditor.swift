import AppKit
import MurmurDictionary
import SwiftUI

struct CorrectionEditor: View {
    let run: DictationRun
    @Bindable var dictationController: DictationController

    @Environment(\.dismiss) private var dismiss
    @State private var voiceController: CorrectionVoiceController
    @State private var draft: String
    @State private var remember = true
    @State private var usedVoice = false
    @State private var isSaving = false
    @State private var message: String?
    @State private var originalAudio: NSSound?

    init(run: DictationRun, dictationController: DictationController) {
        self.run = run
        self.dictationController = dictationController
        _voiceController = State(initialValue: CorrectionVoiceController())
        _draft = State(initialValue: run.text)
    }

    private var heardText: String { run.correction?.heardText ?? run.text }

    private var plan: CorrectionLearningPlan {
        CorrectionLearner.plan(heard: heardText, intended: draft)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.wide) {
                header
                heardSection
                intendedSection
                learningSection
                if let message {
                    Text(message)
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                actions
            }
            .padding(DS.Space.panel)
        }
        .scrollContentBackground(.hidden)
        .background(DS.Color.canvas)
        .frame(width: DS.Size.correctionSheetWidth)
        .frame(minHeight: DS.Size.correctionSheetMinHeight)
        .interactiveDismissDisabled(isSaving)
        .onAppear { dictationController.suspendHotkeyForModalInput() }
        .onDisappear {
            originalAudio?.stop()
            voiceController.cancel()
            dictationController.resumeHotkeyAfterModalInput()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Text("Correct dictation")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
            Text("Edit the text first. Dictate can fill the field, but nothing is saved until you choose Save correction.")
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var heardSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack {
                Text("MURMURE HEARD")
                    .font(DS.Font.eyebrow)
                    .tracking(DS.Font.silkscreenTracking)
                    .foregroundStyle(DS.Color.inkSecondary)
                Spacer()
                if let audioFile = run.audioFile,
                   AudioHistoryStore.url(for: audioFile) != nil {
                    Button("Play original", systemImage: "play.fill") { playOriginal(audioFile) }
                        .buttonStyle(.bordered)
                        .tint(DS.Color.ink)
                        .disabled(voiceController.state.isBusy || isSaving)
                }
            }
            ScrollView {
                Text(heardText.isEmpty ? "(Nothing recognized)" : heardText)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: DS.Size.correctionOriginalMaxHeight)
            .padding(DS.Space.base)
            .background(DS.Color.panel, in: .rect(cornerRadius: DS.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            }
        }
    }

    private var intendedSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack {
                Text("I MEANT")
                    .font(DS.Font.eyebrow)
                    .tracking(DS.Font.silkscreenTracking)
                    .foregroundStyle(DS.Color.inkSecondary)
                Spacer()
                voiceButton
            }
            TextEditor(text: $draft)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .scrollContentBackground(.hidden)
                .padding(DS.Space.snug)
                .frame(height: DS.Size.correctionTextEditorHeight)
                .background(DS.Color.panel, in: .rect(cornerRadius: DS.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.control)
                        .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                }
                .disabled(voiceController.state.isBusy || isSaving)
                .accessibilityLabel("I meant")
                .accessibilityHint("Edit the text Murmure should have written")
        }
    }

    private var voiceButton: some View {
        Button {
            if voiceController.state.canStop {
                voiceController.stop()
            } else if voiceController.state == .idle {
                startVoice()
            }
        } label: {
            Label(voiceButtonTitle, systemImage: voiceController.state.canStop ? "stop.fill" : "mic.fill")
        }
        .buttonStyle(.bordered)
        .tint(voiceController.state.isRecording ? DS.Color.record : DS.Color.ink)
        .disabled(voiceController.state == .finishing || isSaving)
        .accessibilityLabel(voiceButtonTitle)
    }

    private var voiceButtonTitle: String {
        switch voiceController.state {
        case .idle: "Dictate"
        case .starting: "Stop"
        case .listening: "Stop"
        case .finishing: "Transcribing…"
        }
    }

    private var learningSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Toggle("Remember for future dictations", isOn: $remember)
                .font(DS.Font.bodyEmphasis)
                .tint(DS.Color.ink)
                .disabled(isSaving)

            if let suggestion = plan.suggestion {
                VStack(alignment: .leading, spacing: DS.Space.tight) {
                    Text(remember ? "RULE TO REMEMBER" : "AVAILABLE RULE")
                        .font(DS.Font.eyebrow)
                        .tracking(DS.Font.silkscreenTracking)
                        .foregroundStyle(DS.Color.inkSecondary)
                    Text("“\(suggestion.hear)” → “\(suggestion.write)”")
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                        .textSelection(.enabled)
                    if !remember {
                        Text("The corrected history will be saved without adding this rule to the dictionary.")
                            .font(DS.Font.label)
                            .foregroundStyle(DS.Color.inkSecondary)
                    }
                }
            } else {
                Text(historyOnlyExplanation(for: plan.reason))
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.base)
        .background(DS.Color.well, in: .rect(cornerRadius: DS.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        }
    }

    private var actions: some View {
        HStack(spacing: DS.Space.snug) {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button("Save correction") {
                Task { await save() }
            }
                .buttonStyle(.borderedProminent)
                .tint(DS.Color.ink)
                .keyboardShortcut(.defaultAction)
                .disabled(voiceController.state.isBusy || isSaving || !canSave)
        }
    }

    private var canSave: Bool {
        CorrectionSavePolicy.canSave(
            draft: draft,
            run: run,
            plan: plan,
            remember: remember
        )
    }

    private func startVoice() {
        message = nil
        originalAudio?.stop()
        originalAudio = nil
        voiceController.start { outcome in
            switch outcome {
            case .transcript(let text):
                draft = text
                usedVoice = true
            case .blankAudio:
                message = "No words were recognized. Your edited text is unchanged."
            case .failure(let detail):
                message = detail
            case .cancelled:
                break
            }
        }
    }

    private func save() async {
        guard canSave, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let rememberedRule = remember ? plan.suggestion : nil
        let inputMethod: TranscriptCorrectionRecord.InputMethod
        if draft == run.text, let previousMethod = run.correction?.inputMethod {
            inputMethod = previousMethod
        } else {
            inputMethod = usedVoice ? .voiceAssisted : .typed
        }
        let result = await RunLog.saveCorrection(
            id: run.id,
            intendedText: draft,
            inputMethod: inputMethod,
            rememberedRule: rememberedRule
        )
        switch result {
        case .saved:
            dismiss()
        case .historyFailed:
            message = "Couldn’t save this correction. Check that your history drive is available, then try again."
        case .rulePending:
            message = "Correction saved. The rule is pending; Murmure will retry now, then on your next save or launch if the drive stays unavailable."
        case .rememberedMetadataPending:
            message = "Correction and dictionary rule saved. Murmure will reconcile the history status automatically."
        }
    }

    private func playOriginal(_ audioFile: String) {
        guard let url = AudioHistoryStore.url(for: audioFile),
              let sound = NSSound(contentsOf: url, byReference: true) else {
            message = "The original audio is not available."
            return
        }
        originalAudio?.stop()
        originalAudio = sound
        guard sound.play() else {
            originalAudio = nil
            message = "The original audio could not be played."
            return
        }
    }

    private func historyOnlyExplanation(for reason: CorrectionLearningUnavailableReason?) -> String {
        switch reason {
        case .blankIntended:
            "This blank edit can be saved in history, but it cannot become a dictionary rule."
        case .insertionOnly, .deletionOnly:
            "This edit adds or removes words, so it is safe for history only."
        case .punctuationOnly, .noWordChange:
            "This edit does not change a word, so it is safe for history only."
        case .multiline:
            "Multiline edits are saved in history without creating a dictionary rule."
        case .dictionarySyntax:
            "Text containing dictionary syntax is saved in history without creating a rule."
        case .tooManyWords, .tooLong:
            "This edit is too broad for an automatic rule, but it can still be saved in history."
        case .insufficientContext:
            "There is not enough surrounding context for a safe future rule. The edit can still be saved in history."
        case .validationFailed:
            "Murmure could not prove this rule changes only the intended words, so the edit will stay in history."
        case nil:
            "This correction will be saved in history without creating a dictionary rule."
        }
    }
}

enum CorrectionSavePersistenceStep: Equatable {
    case correctedHistory
    case dictionary
    case rememberedMetadata
}

enum CorrectionSavePolicy {
    static func persistenceSteps(
        remember: Bool,
        suggestion: CorrectionRuleSuggestion?
    ) -> [CorrectionSavePersistenceStep] {
        guard remember, suggestion != nil else { return [.correctedHistory] }
        return [.correctedHistory, .dictionary, .rememberedMetadata]
    }

    static func canSave(
        draft: String,
        run: DictationRun,
        plan: CorrectionLearningPlan,
        remember: Bool
    ) -> Bool {
        guard draft == run.text else { return true }
        guard remember, let suggestion = plan.suggestion else { return false }
        return suggestion != run.correction?.rememberedRule
    }
}
