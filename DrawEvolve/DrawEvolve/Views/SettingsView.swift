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

    var body: some View {
        NavigationStack {
            Form {
                accountSection
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
        }
    }

    // MARK: - Sections

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
