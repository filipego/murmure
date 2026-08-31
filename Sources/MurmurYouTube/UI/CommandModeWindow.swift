import SwiftUI

struct CommandModeWindow: View {
    @Bindable var controller: LocalCommandController

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.wide) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text(L10n.text("Command Mode"))
                    .font(DS.Font.display)
                    .foregroundStyle(DS.Color.ink)
                Text(L10n.text(subtitle))
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
            }

            content

            Spacer(minLength: 0)
            actions
        }
        .padding(DS.Space.panel)
        .frame(width: DS.Size.commandModeWidth, height: DS.Size.commandModeHeight)
        .background(DS.Color.canvas)
        .onDisappear {
            if controller.state != .idle { controller.cancel() }
        }
    }

    private var subtitle: String {
        if let source = controller.sourceApplicationName {
            return L10n.format("Local transformation for selected text in %@.", arguments: [source])
        }
        return "Selected text and your instruction stay on this Mac."
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            messagePanel("Select text in another app, then hold the configured Command Mode shortcut.")
        case .recordingInstruction:
            VStack(alignment: .leading, spacing: DS.Space.base) {
                Text(L10n.text("Recording instruction…"))
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                VUMeter(level: controller.level, isActive: true)
                    .frame(height: DS.Size.microphoneTestMeterHeight)
                Text(controller.instructionTranscript.isEmpty
                    ? L10n.text("Speak the change you want, then release the shortcut.")
                    : controller.instructionTranscript)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .commandPanel()
        case .processing:
            VStack(alignment: .leading, spacing: DS.Space.base) {
                ProgressView()
                Text(L10n.text("Creating a local proposal…"))
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                Text(L10n.text("Murmure is using Apple's on-device model. Nothing has been replaced."))
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            .commandPanel()
        case let .review(original, _, notice):
            HStack(alignment: .top, spacing: DS.Space.base) {
                reviewPanel(title: "Original", text: original)
                VStack(alignment: .leading, spacing: DS.Space.tight) {
                    Text(L10n.text("Proposal"))
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                    TextEditor(text: Binding(
                        get: { proposedText },
                        set: { controller.updateProposal($0) }
                    ))
                    .font(DS.Font.body)
                    .scrollContentBackground(.hidden)
                    .padding(DS.Space.tight)
                    .background(DS.Color.well, in: .rect(cornerRadius: DS.Radius.control))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.control)
                            .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                    }
                    .accessibilityLabel(L10n.text("Proposed replacement"))
                    if let notice {
                        Text(notice)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        case let .failed(message):
            messagePanel(message)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: DS.Space.snug) {
            switch controller.state {
            case .review:
                Button(L10n.text("Cancel")) { closeAndCancel() }
                Spacer()
                Button(L10n.text("Copy proposal")) {
                    if controller.copyProposal() { dismissWindow(id: "command-mode") }
                }
                .buttonStyle(.bordered)
                Button(L10n.text("Replace selected text")) {
                    if controller.replaceProposal() == .replaced {
                        dismissWindow(id: "command-mode")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Color.ink)
                .keyboardShortcut(.defaultAction)
            case .recordingInstruction, .processing:
                Spacer()
                Button(L10n.text("Cancel")) { closeAndCancel() }
            case .failed, .idle:
                Spacer()
                Button(L10n.text("Done")) { closeAndCancel() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var proposedText: String {
        if case let .review(_, proposed, _) = controller.state { return proposed }
        return ""
    }

    private func reviewPanel(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Text(L10n.text(title))
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            ScrollView {
                Text(text)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DS.Space.base)
            .background(DS.Color.well, in: .rect(cornerRadius: DS.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func messagePanel(_ message: String) -> some View {
        Text(L10n.text(message))
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .commandPanel()
    }

    private func closeAndCancel() {
        controller.cancel()
        dismissWindow(id: "command-mode")
    }
}

private extension View {
    func commandPanel() -> some View {
        padding(DS.Space.roomy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.panel, in: .rect(cornerRadius: DS.Radius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.panel)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            }
    }
}
