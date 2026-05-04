//
//  PromptEditView.swift
//  DrawEvolve
//
//  Bounded-knobs editor for a custom prompt. Intentionally NO freeform text
//  field — the user picks values from closed enums and the Worker maps each
//  value to a curated server-side fragment. Free text would re-introduce the
//  prompt-injection footgun the styleModifier audit flagged. See
//  CUSTOMPROMPTSPLAN.md §2.3.
//

import SwiftUI

struct PromptEditView: View {
    /// nil = creating a brand-new prompt; non-nil = editing an existing one.
    /// Edit-mode pre-populates the knobs from the row and patches on save.
    let editing: CustomPrompt?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = CustomPromptManager.shared

    @State private var name: String
    @State private var focus: PromptFocus?
    @State private var tone: PromptTone?
    @State private var depth: PromptDepth?
    @State private var techniques: Set<PromptTechnique>
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(editing: CustomPrompt? = nil) {
        self.editing = editing
        _name       = State(initialValue: editing?.name ?? "")
        _focus      = State(initialValue: editing?.parameters.focus)
        _tone       = State(initialValue: editing?.parameters.tone)
        _depth      = State(initialValue: editing?.parameters.depth)
        _techniques = State(initialValue: Set(editing?.parameters.techniques ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Anatomy drills", text: $name)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                }

                Section {
                    enumPicker(
                        title: "Critique focus",
                        cases: PromptFocus.allCases,
                        selection: $focus,
                    )
                } footer: {
                    Text("Bias which area gets picked as the Focus Area. \"General\" lets the AI choose freely.")
                }

                Section {
                    enumPicker(
                        title: "Tone",
                        cases: PromptTone.allCases,
                        selection: $tone,
                    )
                } footer: {
                    Text("How direct the AI should be. Honest critique is the goal at every setting.")
                }

                Section {
                    enumPicker(
                        title: "Depth",
                        cases: PromptDepth.allCases,
                        selection: $depth,
                    )
                } footer: {
                    Text("Length and detail of each critique.")
                }

                Section {
                    ForEach(PromptTechnique.allCases) { t in
                        Button {
                            if techniques.contains(t) {
                                techniques.remove(t)
                            } else {
                                techniques.insert(t)
                            }
                        } label: {
                            HStack {
                                Text(t.displayName).foregroundColor(.primary)
                                Spacer()
                                if techniques.contains(t) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Technique emphasis")
                } footer: {
                    Text("Bias the \"Try This\" suggestions. Pick none for default mixed advice.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundColor(.red) }
                }
            }
            .navigationTitle(editing == nil ? "New Prompt" : "Edit Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func enumPicker<Option: Identifiable & Hashable>(
        title: String,
        cases: [Option],
        selection: Binding<Option?>,
    ) -> some View where Option.ID: Hashable {
        Picker(title, selection: selection) {
            Text("Default").tag(Option?.none)
            ForEach(cases) { option in
                Text(displayLabel(for: option)).tag(Option?.some(option))
            }
        }
        .pickerStyle(.menu)
    }

    private func displayLabel<Option>(for option: Option) -> String {
        if let f = option as? PromptFocus     { return f.displayName }
        if let t = option as? PromptTone      { return t.displayName }
        if let d = option as? PromptDepth     { return d.displayName }
        if let q = option as? PromptTechnique { return q.displayName }
        return "\(option)"
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let params = PromptParameters(
            focus: focus,
            tone: tone,
            depth: depth,
            // Persist techniques in canonical TECHNIQUE_OPTIONS order so
            // two clients editing the same set produce equal payloads.
            techniques: techniques.isEmpty ? nil : PromptTechnique.allCases.filter { techniques.contains($0) },
        )
        isSaving = true
        defer { isSaving = false }
        do {
            if let editing {
                try await manager.update(id: editing.id, name: trimmed, parameters: params)
            } else {
                try await manager.create(name: trimmed, parameters: params)
            }
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

#Preview {
    PromptEditView(editing: nil)
}
