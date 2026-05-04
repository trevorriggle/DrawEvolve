//
//  PromptListView.swift
//  DrawEvolve
//
//  List of the user's saved bounded-knobs prompts. Tap a row to use that
//  prompt for the next critique (writes the row id to the same UserDefaults
//  key the existing My Prompts preset picker writes); tap "New" to author;
//  swipe to delete (soft delete server-side).
//

import SwiftUI

struct PromptListView: View {
    @ObservedObject private var manager = CustomPromptManager.shared

    @State private var showCreate = false
    @State private var editingPrompt: CustomPrompt?

    /// Mirrors the @AppStorage key in GalleryView. The stored value is the
    /// `preset_id` string we send to the Worker — `studio_mentor` etc., or
    /// `custom:<uuid>` for one of the user's saved bounded-knobs prompts.
    /// Three sources, one value: this view, GalleryView, and OpenAIManager.
    @AppStorage("selectedPresetID") private var selectedPresetID: String = "studio_mentor"

    var body: some View {
        Group {
            if manager.isLoading && manager.prompts.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if manager.prompts.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("My Prompts")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
            }
        }
        .task { await manager.refresh() }
        .refreshable { await manager.refresh() }
        .sheet(isPresented: $showCreate) {
            PromptEditView(editing: nil)
        }
        .sheet(item: $editingPrompt) { prompt in
            PromptEditView(editing: prompt)
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(manager.prompts) { prompt in
                    Button {
                        selectedPresetID = "custom:\(prompt.id.uuidString.lowercased())"
                    } label: {
                        row(for: prompt)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task {
                                try? await manager.delete(id: prompt.id)
                                // If the deleted prompt was selected, fall
                                // back to the default voice — otherwise the
                                // next critique would request a custom row
                                // that no longer resolves.
                                if selectedPresetID == "custom:\(prompt.id.uuidString.lowercased())" {
                                    selectedPresetID = "studio_mentor"
                                }
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editingPrompt = prompt
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            } footer: {
                if let err = manager.lastError {
                    Text(err).foregroundColor(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(for prompt: CustomPrompt) -> some View {
        let presetIDForRow = "custom:\(prompt.id.uuidString.lowercased())"
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(prompt.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(summary(for: prompt.parameters))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if selectedPresetID == presetIDForRow {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    /// Compact summary line for the list row. Shows the knobs that are set;
    /// when nothing is set, shows "Default settings" so the row never looks
    /// blank. Kept short — long descriptions belong in the editor, not the
    /// list.
    private func summary(for p: PromptParameters) -> String {
        var parts: [String] = []
        if let f = p.focus { parts.append(f.displayName) }
        if let t = p.tone, t != .balanced { parts.append(t.displayName) }
        if let d = p.depth, d != .standard { parts.append(d.displayName) }
        if let techniques = p.techniques, !techniques.isEmpty {
            parts.append("\(techniques.count) technique\(techniques.count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "Default settings" : parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 60))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No saved prompts yet")
                .font(.headline)
            Text("Tap + to create one. Pick the focus, tone, depth, and techniques you want the AI to bias toward.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                showCreate = true
            } label: {
                Label("New Prompt", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding()
    }
}

#Preview {
    NavigationStack { PromptListView() }
}
