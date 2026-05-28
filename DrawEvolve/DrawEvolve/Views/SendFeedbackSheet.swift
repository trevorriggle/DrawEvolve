//
//  SendFeedbackSheet.swift
//  DrawEvolve
//
//  In-app feedback submission form. Presented as a sheet from
//  Settings → Send Feedback. Inserts into public.feedback_submissions
//  (migration 0018) via FeedbackService — RLS-protected per-user
//  inserts, server-enforced rate limit at 5/hour/user.
//
//  STATE MACHINE:
//    .idle      → user fills the form
//    .sending   → button shows ProgressView, form disabled
//    .succeeded → "Sent — thanks." alert; OK dismisses the sheet
//    .failed    → inline red error row above the Send button; form
//                 stays editable so the user can edit + retry
//
//  RATE-LIMIT UX: FeedbackError.rateLimited maps to a specific
//  "you've sent feedback recently" message via .userFacingMessage —
//  the user knows the submission was rejected for a reason, not a
//  network blip.
//

import SwiftUI

struct SendFeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var category: FeedbackCategory = .bug
    @State private var messageText: String = ""
    @State private var sendState: SendState = .idle

    enum SendState: Equatable {
        case idle
        case sending
        case failed(String)
        case succeeded
    }

    private let minChars = 10
    private let maxChars = 4000

    var body: some View {
        NavigationStack {
            Form {
                categorySection
                messageSection
                if case .failed(let msg) = sendState {
                    errorSection(message: msg)
                }
                sendSection
            }
            .navigationTitle("Send Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(sendState == .sending)
                }
            }
            .alert(
                "Sent — thanks.",
                isPresented: successAlertBinding,
                actions: {
                    Button("OK") { dismiss() }
                },
                message: {
                    Text("Your feedback is in. Keep it coming.")
                }
            )
        }
    }

    // MARK: - Form sections

    private var categorySection: some View {
        Section {
            Picker("Category", selection: $category) {
                ForEach(FeedbackCategory.allCases) { cat in
                    Text(cat.label).tag(cat)
                }
            }
            .pickerStyle(.menu)
            .disabled(sendState == .sending)
        } header: {
            Text("What's the issue?")
        }
    }

    private var messageSection: some View {
        Section {
            // TextEditor doesn't take a placeholder; ZStack a hint when empty
            // so the field doesn't read as broken on first focus.
            ZStack(alignment: .topLeading) {
                if messageText.isEmpty {
                    Text("Describe what you ran into. The more specific the better.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $messageText)
                    .frame(minHeight: 140)
                    .disabled(sendState == .sending)
            }

            HStack {
                Spacer()
                Text("\(trimmedCount) / \(maxChars)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(trimmedCount > maxChars ? .red : .secondary)
            }
        } header: {
            Text("Tell us about it")
        } footer: {
            if trimmedCount > 0 && trimmedCount < minChars {
                Text("At least \(minChars) characters, so we can act on it.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorSection(message: String) -> some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sendSection: some View {
        Section {
            Button(action: send) {
                HStack(spacing: 8) {
                    if sendState == .sending {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(sendState == .sending ? "Sending…" : "Send Feedback")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .foregroundStyle(.white)
                .padding(.vertical, 4)
                .listRowBackground(canSend ? Color.accentColor : Color.gray.opacity(0.4))
            }
            .disabled(!canSend)
        } footer: {
            Text("We read every submission. We can't reply individually, but it shapes what ships next.")
        }
    }

    // MARK: - Derived state

    private var trimmedCount: Int {
        messageText.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    private var canSend: Bool {
        trimmedCount >= minChars && trimmedCount <= maxChars && sendState != .sending
    }

    /// Binding for the success alert. SwiftUI .alert requires a Bool
    /// binding; the setter is a no-op because the OK button handles
    /// dismissal (and we don't want the alert to spontaneously re-open
    /// if state mutates elsewhere).
    private var successAlertBinding: Binding<Bool> {
        Binding(
            get: { sendState == .succeeded },
            set: { _ in /* OK button dismisses; ignore alert auto-set */ }
        )
    }

    // MARK: - Submit

    private func send() {
        guard canSend else { return }
        sendState = .sending

        Task {
            do {
                try await FeedbackService.shared.submit(
                    category: category,
                    body: messageText
                )
                await MainActor.run { sendState = .succeeded }
            } catch let error as FeedbackError {
                await MainActor.run { sendState = .failed(error.userFacingMessage) }
            } catch {
                await MainActor.run {
                    sendState = .failed("Couldn't send. Check your connection and try again.")
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SendFeedbackSheet()
}
