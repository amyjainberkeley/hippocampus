// UserDictionaryEditor.swift — SwiftUI editor for the user dictionary
// (cycle 8.42, `docs/research/2026-07-12-recall-ui-audit.md` extension).
//
// Presents a single "Custom Names" section: a stack of rows, each with a
// canonical name field + a comma-separated alias field. Add / remove is
// two clicks. Errors surface inline; the model is validated on every save.
//
// # Where it lives
//
// One-scene Settings pane. The Recall app has no Settings tab yet
// (the audit noted this as a "future" surface); we introduce a minimal
// one here that hosts this editor. Future settings can grow into the
// same enclosing view without another architectural pass.
//
// # Model → disk
//
// The view holds a `UserDictionary` in `@State`. Save-on-blur wraps the
// call to `saveUserDictionary(_:)`; any thrown `UserDictionaryError` is
// rendered in a red inline banner. The user is never left with a bogus
// on-disk state — the validator runs before the write.

import RecallUIKit
import SwiftUI

/// Standalone editor view. Loads the on-disk dictionary lazily; use the
/// `initial` parameter for previews / tests.
struct UserDictionaryEditor: View {
    /// Working copy of the dictionary. Mutated as the user types; written
    /// on Save.
    @State private var draft: UserDictionary
    /// Comma-separated alias buffers (the on-disk shape is a list, but the
    /// UI shows one text field per row). Keyed by canonical name at load;
    /// after any edit the caller uses `draft.entries[i].aliases` directly.
    @State private var aliasBuffers: [String]
    /// Canonical-name text buffers. Same shape as `aliasBuffers`.
    @State private var canonicalBuffers: [String]
    @State private var errorMessage: String? = nil
    @State private var savedIndicator: Bool = false

    init(initial: UserDictionary = (try? loadUserDictionary()) ?? .empty) {
        let d = initial
        self._draft = State(initialValue: d)
        self._aliasBuffers = State(initialValue: d.entries.map { $0.aliases.joined(separator: ", ") })
        self._canonicalBuffers = State(initialValue: d.entries.map(\.canonical))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let err = errorMessage {
                    Text(err)
                        .foregroundStyle(Color.brandError)
                        .font(.callout)
                        .padding(8)
                        .background(Color.brandError.opacity(0.1))
                        .cornerRadius(6)
                }
                if draft.entries.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(draft.entries.enumerated()), id: \.offset) { idx, _ in
                        row(at: idx)
                    }
                }
                HStack {
                    Button {
                        addRow()
                    } label: {
                        Label("Add name", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.brandMint)
                    Spacer()
                    if savedIndicator {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.brandMint)
                            .transition(.opacity)
                    }
                    Button("Save") { commit() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandMint)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(20)
        }
        .background(Color.brandBgPrimary)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Custom Names")
                .font(.title2.bold())
                .foregroundStyle(Color.brandFgPrimary)
            Text(
                "Tell Hippocampus that a person or topic goes by multiple names. "
                    + "Aliases match with high confidence — the brain treats them as the "
                    + "same person or topic at query time."
            )
            .font(.callout)
            .foregroundStyle(Color.brandFgSecondary)
            Text("Example: canonical \"Amy Jain\", aliases: AJ, Amy, @amyjainberkeley")
                .font(.callout)
                .italic()
                .foregroundStyle(Color.brandFgMuted)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No custom names yet.")
                .foregroundStyle(Color.brandFgSecondary)
            Text("Click Add name to teach Hippocampus your vocabulary.")
                .foregroundStyle(Color.brandFgMuted)
                .font(.callout)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brandBgPrimary.opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.brandCardBorder, lineWidth: 1)
        )
    }

    /// One editable row. Text fields write to the *buffer* arrays; commit()
    /// rebuilds `draft.entries` from the buffers so the validation error
    /// path always operates on the just-typed content.
    @ViewBuilder
    private func row(at idx: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Canonical name (e.g. Amy Jain)", text: bindingCanonical(idx))
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) {
                    removeRow(at: idx)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            TextField(
                "Aliases, comma-separated (e.g. AJ, Amy, @amyjainberkeley)",
                text: bindingAliases(idx)
            )
            .textFieldStyle(.roundedBorder)
        }
        .padding(10)
        .background(Color.brandBgPrimary.opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.brandCardBorder, lineWidth: 1)
        )
    }

    private func bindingCanonical(_ idx: Int) -> Binding<String> {
        Binding(
            get: { canonicalBuffers[idx] },
            set: { canonicalBuffers[idx] = $0 }
        )
    }
    private func bindingAliases(_ idx: Int) -> Binding<String> {
        Binding(
            get: { aliasBuffers[idx] },
            set: { aliasBuffers[idx] = $0 }
        )
    }

    private func addRow() {
        canonicalBuffers.append("")
        aliasBuffers.append("")
        // Also grow `draft.entries` so the ForEach index stays in bounds.
        let entries = draft.entries + [UserDictionaryEntry(canonical: "", aliases: [])]
        draft = UserDictionary(entries: entries, version: draft.version)
    }

    private func removeRow(at idx: Int) {
        canonicalBuffers.remove(at: idx)
        aliasBuffers.remove(at: idx)
        var entries = draft.entries
        entries.remove(at: idx)
        draft = UserDictionary(entries: entries, version: draft.version)
    }

    /// Rebuild `draft.entries` from the text buffers, validate + save.
    private func commit() {
        var newEntries: [UserDictionaryEntry] = []
        for (idx, canonical) in canonicalBuffers.enumerated() {
            let trimmed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && aliasBuffers[idx].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue  // silently drop fully-empty rows
            }
            let aliases = aliasBuffers[idx]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            newEntries.append(
                UserDictionaryEntry(
                    canonical: trimmed,
                    aliases: aliases,
                    createdAtUs: draft.entries.indices.contains(idx)
                        ? draft.entries[idx].createdAtUs : nowUs()
                )
            )
        }
        let candidate = UserDictionary(entries: newEntries, version: draft.version)
        do {
            try saveUserDictionary(candidate)
            draft = candidate
            canonicalBuffers = candidate.entries.map(\.canonical)
            aliasBuffers = candidate.entries.map { $0.aliases.joined(separator: ", ") }
            errorMessage = nil
            withAnimation { savedIndicator = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                withAnimation { savedIndicator = false }
            }
        } catch UserDictionaryError.validationFailed(let msg) {
            errorMessage = "Can't save: \(msg)"
        } catch UserDictionaryError.parseFailed(let msg) {
            errorMessage = "Can't parse: \(msg)"
        } catch UserDictionaryError.ioFailed(let msg) {
            errorMessage = "Couldn't write to disk: \(msg)"
        } catch {
            errorMessage = "Unexpected error: \(error)"
        }
    }

    private func nowUs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }
}
