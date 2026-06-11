//
//  SettingsView.swift
//  DrawEvolve
//
//  Phase 6 settings surface — sign out, delete account, app metadata,
//  policy links. Reachable via the gear icon inside the canvas's
//  collapsible chrome (hides when the chevron collapses chrome).
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var showSignOutConfirm = false
    @State private var showDeleteSheet = false
    @State private var signOutInFlight = false
    @State private var showBetaNotice = false
    @State private var showSendFeedback = false

    // Tutorial flags. Replay Tutorial resets all five so the cards re-
    // present AND the surface-specific coach-marks re-arm. The actual
    // present is requested via `tutorialReplayRequest` below — a
    // monotonic counter, NOT a flag edge — so it fires every time.
    @AppStorage("hasSeenTutorialV1") private var hasSeenTutorialV1 = false
    @AppStorage("hasSeenPromptInputBannerV1") private var hasSeenPromptInputBannerV1 = false
    @AppStorage("hasSeenGetFeedbackCoachMarkV1") private var hasSeenGetFeedbackCoachMarkV1 = false
    @AppStorage("hasSeenAskEveCoachMarkV1") private var hasSeenAskEveCoachMarkV1 = false
    @AppStorage("hasSeenGalleryTourV1") private var hasSeenGalleryTourV1 = false

    /// Replay-request token. Each Replay Tutorial tap increments it;
    /// ContentView listens via onChange. A counter ALWAYS changes, so
    /// the cards re-present regardless of the tutorial's completion
    /// state — the previous trigger ("set hasSeenTutorialV1 = false")
    /// was an edge that never fired when the flag was already false
    /// (tutorial not yet completed), leaving the button dead.
    @AppStorage("tutorialReplayRequestV1") private var tutorialReplayRequest = 0

    var body: some View {
        NavigationStack {
            Form {
                infoSection
                accountSection
                helpSection
                actionsSection
                legalSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Sign out of DrawEvolve?", isPresented: $showSignOutConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) {
                    Task { await performSignOut() }
                }
            } message: {
                Text("Your drawings stay safe in the cloud. Sign back in any time to pick up where you left off.")
            }
            .sheet(isPresented: $showDeleteSheet) {
                DeleteAccountConfirmationSheet()
            }
            .sheet(isPresented: $showSendFeedback) {
                SendFeedbackSheet()
            }
            .fullScreenCover(isPresented: $showBetaNotice) {
                BetaTransparencyPopup(isPresented: $showBetaNotice)
            }
        }
    }

    // MARK: - Sections

    /// Beta Notice + Replay Tutorial — re-access paths. Side-by-side
    /// buttons rendered as a single Form row with clear background so
    /// they read as floating actions, not list rows.
    ///
    /// Replay Tutorial resets all 5 tutorial flags and dismisses the
    /// sheet. ContentView's onChange(of: hasSeenTutorialV1) picks up the
    /// reset and presents the cards in replay mode over whatever screen
    /// the user was on (per v3 Q4 decision — do not navigate to LaunchHome).
    private var infoSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    showBetaNotice = true
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "info.bubble")
                            .font(.title3)
                        Text("Beta Notice")
                            .font(.footnote.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                Button {
                    replayTutorial()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                        Text("Replay Tutorial")
                            .font(.footnote.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
        }
    }

    /// Send Feedback row + footer. Inserts into public.feedback_submissions
    /// (migration 0018) via FeedbackService — RLS-protected, server-
    /// enforced 5/hr/user rate limit. Sheet handles category picker,
    /// message body, and error/success states.
    private var helpSection: some View {
        Section {
            Button {
                showSendFeedback = true
            } label: {
                HStack {
                    Image(systemName: "envelope")
                        .foregroundStyle(.accent)
                        .frame(width: 24)
                    Text("Send Feedback")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Help")
        } footer: {
            Text("We read every submission. We can't reply individually, but it shapes what ships next.")
        }
    }

    private var accountSection: some View {
        Section("Account") {
            HStack {
                Text("Email")
                Spacer()
                Text(authManager.currentUser?.email ?? "—")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                showSignOutConfirm = true
            } label: {
                HStack {
                    Text("Sign Out")
                    if signOutInFlight { Spacer(); ProgressView() }
                }
            }
            .disabled(signOutInFlight)

            Button(role: .destructive) {
                showDeleteSheet = true
            } label: {
                Text("Delete Account")
            }
        } footer: {
            Text("Deleting your account permanently removes your drawings, critique history, and usage data. This cannot be undone.")
        }
    }

    private var legalSection: some View {
        Section {
            Link("Privacy Policy", destination: URL(string: "https://drawevolve.com/privacy")!)
            Link("Terms of Service", destination: URL(string: "https://drawevolve.com/terms")!)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Self.versionAndBuild).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    /// Reset all five tutorial flags (so the surface coach-marks re-arm),
    /// bump the replay-request token (so ContentView.SignedInRoot
    /// presents the cards in replay mode — unconditionally, whether or
    /// not the tutorial was ever completed), then dismiss the sheet.
    private func replayTutorial() {
        hasSeenTutorialV1 = false
        hasSeenPromptInputBannerV1 = false
        hasSeenGetFeedbackCoachMarkV1 = false
        hasSeenAskEveCoachMarkV1 = false
        hasSeenGalleryTourV1 = false
        tutorialReplayRequest += 1
        dismiss()
    }

    private func performSignOut() async {
        signOutInFlight = true
        defer { signOutInFlight = false }
        await authManager.signOut()
        // No explicit dismiss — ContentView swaps to AuthGateView via
        // authStateChanges and the whole sheet stack tears down with it.
    }

    private static var versionAndBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

// MARK: - Delete confirmation sheet

private struct DeleteAccountConfirmationSheet: View {
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var typedConfirmation = ""
    @State private var inFlight = false
    @State private var inlineError: String?

    private var confirmEnabled: Bool {
        // Case-sensitive equality — lowercase "delete" must NOT enable the
        // button. This is intentional friction.
        typedConfirmation == "DELETE" && !inFlight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Delete your account?")
                .font(.title2.bold())

            Text("This permanently deletes your account, all drawings, all critiques, and all usage history. This cannot be undone.")
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Type DELETE to confirm")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("", text: $typedConfirmation)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .disabled(inFlight)
            }

            if let inlineError {
                Text(inlineError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(inFlight)

                Button(role: .destructive) {
                    Task { await performDelete() }
                } label: {
                    HStack {
                        if inFlight { ProgressView() }
                        Text(inFlight ? "Deleting…" : "Delete Account")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!confirmEnabled)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
    }

    private func performDelete() async {
        inFlight = true
        inlineError = nil
        defer { inFlight = false }
        do {
            try await authManager.deleteAccount()
            // No dismiss() — ContentView routes to AuthGateView on the
            // signedOut state change and the whole modal stack unmounts.
        } catch {
            // Keep the user signed in with cloud data intact. Inline copy
            // is friendly and step-aware (see AuthError.deleteFailed).
            inlineError = error.localizedDescription
        }
    }
}
