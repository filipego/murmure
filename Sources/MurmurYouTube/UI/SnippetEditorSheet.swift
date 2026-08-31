import SwiftUI

struct SnippetEditorSheet: View {
    let original: SnippetEntry

    @Environment(\.dismiss) private var dismiss
    @State private var trigger: String
    @State private var replacement: String
    @State private var isEnabled: Bool
    @State private var isSaving = false
    @State private var message: String?

    init(entry: SnippetEntry) {
        original = entry
        _trigger = State(initialValue: entry.trigger)
        _replacement = State(initialValue: entry.replacement)
        _isEnabled = State(initialValue: entry.isEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.wide) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text(L10n.text(original.trigger.isEmpty ? "Add snippet" : "Edit snippet"))
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                Text(L10n.text("Murmure replaces only a complete matching utterance. It never changes a phrase inside ordinary prose."))
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DS.Space.snug) {
                Text(L10n.text("WHEN I SAY"))
                    .font(DS.Font.eyebrow)
                    .tracking(DS.Font.silkscreenTracking)
                    .foregroundStyle(DS.Color.inkSecondary)
                TextField(L10n.text("my address"), text: $trigger)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSaving)
            }

            VStack(alignment: .leading, spacing: DS.Space.snug) {
                Text(L10n.text("WRITE"))
                    .font(DS.Font.eyebrow)
                    .tracking(DS.Font.silkscreenTracking)
                    .foregroundStyle(DS.Color.inkSecondary)
                TextEditor(text: $replacement)
                    .font(DS.Font.body)
                    .scrollContentBackground(.hidden)
                    .padding(DS.Space.tight)
                    .frame(height: DS.Size.correctionTextEditorHeight)
                    .background(DS.Color.well, in: .rect(cornerRadius: DS.Radius.control))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.control)
                            .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                    }
                    .disabled(isSaving)
                Text(L10n.text("Line breaks are kept in the inserted text."))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }

            Toggle(L10n.text("Enabled"), isOn: $isEnabled)
                .disabled(isSaving)

            if let message {
                Text(L10n.text(message))
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: DS.Space.snug) {
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(L10n.text(isSaving ? "Saving…" : "Save snippet")) {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Color.ink)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(DS.Space.panel)
        .frame(width: DS.Size.correctionSheetWidth)
        .background(DS.Color.canvas)
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        message = nil
        defer { isSaving = false }
        let entry = SnippetEntry(
            id: original.id,
            trigger: trigger,
            replacement: replacement,
            isEnabled: isEnabled
        )
        if let issue = await SnippetStore.shared.upsert(entry) {
            message = issue.message
            return
        }
        dismiss()
    }
}
