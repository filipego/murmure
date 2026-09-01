import SwiftUI

/// First-class workspace for reusable phrases. Snippet persistence remains local and is owned
/// by `SnippetStore`; this panel only coordinates the list and its editor affordances.
struct SnippetPanel: View {
    @State private var snippets = SnippetStore.shared
    @State private var snippetDraft: SnippetEntry?
    @State private var pendingDeletion: SnippetEntry?
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.wide) {
                HStack(spacing: DS.Space.snug) {
                    Text(
                        L10n.format(
                            "%d enabled · %d total",
                            arguments: [
                                snippets.entries.filter(\.isEnabled).count, snippets.entries.count,
                            ]
                        )
                    )
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
                    Spacer()
                    PrimaryActionButton(title: "Add snippet", systemImage: "plus") {
                        message = nil
                        snippetDraft = SnippetEntry(trigger: "", replacement: "")
                    }
                }

                VStack(alignment: .leading, spacing: DS.Space.base) {
                    Text(L10n.text("Reusable phrases"))
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Color.ink)
                    Text(
                        L10n.text(
                            "Say a complete phrase and replace it with reusable local text. Snippets run before dictionary corrections."
                        )
                    )
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if snippets.entries.isEmpty {
                        Text(
                            L10n.text(
                                "No snippets yet. Try “my address,” “email signature,” or any phrase you would say by itself."
                            )
                        )
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(snippets.entries) { entry in
                            snippetRow(entry)
                        }
                    }

                    if let message {
                        Text(L10n.text(message))
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.warning)
                            .fixedSize(horizontal: false, vertical: true)
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
            .padding(DS.Space.panel)
        }
        .scrollContentBackground(.hidden)
        .background(DS.Color.canvas)
        .sheet(item: $snippetDraft) { entry in
            SnippetEditorSheet(entry: entry)
        }
        .alert(
            L10n.text("Delete this snippet?"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button(L10n.text("Delete"), role: .destructive) {
                guard let entry = pendingDeletion else { return }
                pendingDeletion = nil
                Task {
                    if !(await snippets.delete(id: entry.id)) {
                        message =
                            "The snippet could not be deleted. Check that your data drive is available."
                    }
                }
            }
            Button(L10n.text("Cancel"), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(pendingDeletion?.trigger ?? "")
        }
    }

    private func snippetRow(_ entry: SnippetEntry) -> some View {
        HStack(alignment: .top, spacing: DS.Space.snug) {
            Toggle(
                "",
                isOn: Binding(
                    get: { entry.isEnabled },
                    set: { enabled in
                        Task {
                            if !(await snippets.setEnabled(enabled, id: entry.id)) {
                                message =
                                    "The snippet could not be updated. Check that your data drive is available."
                            }
                        }
                    }
                )
            )
            .labelsHidden()
            .accessibilityLabel(L10n.format("Enable %@", arguments: [entry.trigger]))

            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text(entry.trigger)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                Text(entry.replacement.replacingOccurrences(of: "\n", with: " ↵ "))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                message = nil
                snippetDraft = entry
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Color.inkSecondary)
            .help(L10n.text("Edit snippet"))
            .accessibilityLabel(L10n.format("Edit %@", arguments: [entry.trigger]))

            Button {
                pendingDeletion = entry
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Color.inkSecondary)
            .help(L10n.text("Delete snippet"))
            .accessibilityLabel(L10n.format("Delete %@", arguments: [entry.trigger]))
        }
        .padding(DS.Space.base)
        .background(DS.Color.well, in: .rect(cornerRadius: DS.Radius.control))
    }
}
