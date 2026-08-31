import AppKit
import MurmurDictionary
import SwiftUI

/// Local dictionary management. The plain text file remains the source of truth; this panel
/// simply makes the common add, edit, enable, and search actions easy to scan.
struct DictionaryPanel: View {
    @State private var store = DictionaryStore.shared
    @State private var query = ""
    @State private var editing: DictionaryEntry?
    @State private var isAdding = false

    private var entries: [DictionaryEntry] { store.filtered(by: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.snug) {
                SearchField(text: $query, placeholder: "Search terms and corrections")
                PrimaryActionButton(title: "Add entry", systemImage: "plus") { isAdding = true }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel(L10n.text("Add dictionary entry"))
            }
            .padding(.horizontal, DS.Space.panel)
            .padding(.vertical, DS.Space.roomy)

            Rectangle()
                .fill(DS.Color.seam)
                .frame(height: DS.Border.hairline)

            if entries.isEmpty {
                EmptyPanel(
                    label: store.entries.isEmpty ? "Your dictionary is empty" : "No matching entries",
                    detail: store.entries.isEmpty
                        ? "Add names, product terms, or a phrase Murmure often mishears."
                        : "Try a different search."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.tight) {
                        ForEach(entries) { entry in
                            DictionaryRow(
                                entry: entry,
                                onEdit: { editing = entry },
                                onToggle: {
                                    var updated = entry
                                    updated.isEnabled.toggle()
                                    store.update(updated)
                                },
                                onDelete: { store.delete(entry) }
                            )
                        }
                    }
                    .padding(.horizontal, DS.Space.panel)
                    .padding(.vertical, DS.Space.base)
                }
            }

            footer
        }
        .sheet(isPresented: $isAdding) {
            DictionaryEditor(entry: nil) { store.add($0) }
        }
        .sheet(item: $editing) { entry in
            DictionaryEditor(entry: entry) { store.update($0) }
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Space.snug) {
            Text(L10n.format(
                store.entries.count == 1 ? "%d entry" : "%d entries",
                arguments: [store.entries.count]
            ))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
            } label: {
                Label(L10n.text("Reveal dictionary file"), systemImage: "arrow.up.forward.app")
                    .font(DS.Font.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Color.inkSecondary)
            .help(DictionaryStore.fileURL.path)
        }
        .padding(.horizontal, DS.Space.panel)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.well)
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Image(systemName: entry.kind == .correction ? "arrow.triangle.2.circlepath" : "textformat")
                .foregroundStyle(entry.isEnabled ? DS.Color.success : DS.Color.inkSecondary)
                .frame(width: DS.Space.roomy)

            VStack(alignment: .leading, spacing: DS.Space.tight) {
                if entry.kind == .correction {
                    HStack(spacing: DS.Space.tight) {
                        Text(entry.hear)
                            .foregroundStyle(DS.Color.inkSecondary)
                        Image(systemName: "arrow.right")
                            .font(DS.Font.label.weight(.semibold))
                            .foregroundStyle(DS.Color.inkSecondary)
                        Text(entry.write)
                            .font(DS.Font.bodyEmphasis)
                            .foregroundStyle(DS.Color.ink)
                    }
                } else {
                    Text(entry.write)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                }
                Text(L10n.text(entry.kind == .correction ? "Correction" : "Term"))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }

            Spacer(minLength: 0)

            // Keep row actions in the accessibility tree and keyboard order even when the
            // pointer is not over the row. Hover still changes the surface, but it must not be
            // the only way to discover edit, enable/disable, and delete.
            rowButton("Edit", systemImage: "pencil", action: onEdit)
            rowButton(entry.isEnabled ? "Disable" : "Enable", systemImage: entry.isEnabled ? "pause" : "play", action: onToggle)
            rowButton("Delete", systemImage: "trash", action: onDelete)
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .opacity(entry.isEnabled ? 1 : 0.5)
        .background(isHovering ? DS.Color.hover : DS.Color.panel, in: .rect(cornerRadius: DS.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        }
        .onHover { isHovering = $0 }
    }

    private func rowButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .accessibilityLabel(L10n.text(title))
                .frame(width: DS.Space.roomy, height: DS.Space.roomy)
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.Color.inkSecondary)
        .help(L10n.text(title))
    }
}

private struct DictionaryEditor: View {
    let entry: DictionaryEntry?
    let onSave: (DictionaryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: DictionaryEntry.Kind
    @State private var hear: String
    @State private var write: String

    init(entry: DictionaryEntry?, onSave: @escaping (DictionaryEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _kind = State(initialValue: entry?.kind ?? .term)
        _hear = State(initialValue: entry?.hear ?? "")
        _write = State(initialValue: entry?.write ?? "")
    }

    private var draft: DictionaryEntry {
        DictionaryEntry(
            id: entry?.id ?? UUID(),
            kind: kind,
            write: write.trimmingCharacters(in: .whitespacesAndNewlines),
            hear: kind == .correction ? hear.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            isEnabled: entry?.isEnabled ?? true
        )
    }

    private var warnings: [DictionaryWarning] { DictionaryWarning.check(draft) }
    private var isValid: Bool { !draft.write.isEmpty && (kind == .term || !draft.hear.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            Text(L10n.text(entry == nil ? "Add dictionary entry" : "Edit dictionary entry"))
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)

            Picker(L10n.text("Entry type"), selection: $kind) {
                Text(L10n.text("Term")).tag(DictionaryEntry.Kind.term)
                Text(L10n.text("Correction")).tag(DictionaryEntry.Kind.correction)
            }
            .pickerStyle(.segmented)

            if kind == .correction {
                editorField(label: "When you hear", placeholder: "cloud code", text: $hear)
            }
            editorField(
                label: kind == .correction ? "Write" : "Word or phrase",
                placeholder: kind == .correction ? "Claude Code" : "Anthropic",
                text: $write
            )

            ForEach(warnings) { warning in
                Label(L10n.text(warning.message), systemImage: "exclamationmark.triangle")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Save")) {
                    guard isValid else { return }
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 460)
        .background(DS.Color.canvas)
    }

    private func editorField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Text(L10n.text(label).uppercased())
                .font(DS.Font.eyebrow)
                .tracking(DS.Font.silkscreenTracking)
                .foregroundStyle(DS.Color.inkSecondary)
            TextField(L10n.text(placeholder), text: text)
                .textFieldStyle(.roundedBorder)
                .font(DS.Font.body)
        }
    }
}
