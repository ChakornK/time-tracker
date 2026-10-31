import SwiftUI

@MainActor
@Observable
final class SettingsModel {
    private let api: TrackerAPIClient
    private let token: String
    private let onProfileChanged: (APIUser) -> Void
    private(set) var profile: APIUser
    private(set) var isSavingName = false
    private(set) var isSavingEmail = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    var displayName: String
    var newEmail = ""
    var currentPassword = ""

    init(api: TrackerAPIClient, token: String, user: APIUser, onProfileChanged: @escaping (APIUser) -> Void) {
        self.api = api
        self.token = token
        self.onProfileChanged = onProfileChanged
        profile = user
        displayName = user.displayName
    }

    var canChangeEmail: Bool {
        !isSavingEmail && !newEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !currentPassword.isEmpty
    }

    func saveDisplayName() async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Display name cannot be empty."
            return
        }
        clearMessages()
        isSavingName = true
        defer { isSavingName = false }
        do {
            accept(try await api.updateProfile(displayName: trimmed, accessToken: token))
            successMessage = "Display name saved."
        } catch {
            errorMessage = "Display name could not be saved. Check your connection and try again."
        }
    }

    func changeEmail() async {
        let email = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AccountValidation.isValidEmail(email) else {
            errorMessage = "Enter an email address like name@gmail.com."
            return
        }
        clearMessages()
        isSavingEmail = true
        defer { isSavingEmail = false }
        do {
            accept(try await api.updateEmail(email, currentPassword: currentPassword, accessToken: token))
            newEmail = ""
            currentPassword = ""
            successMessage = "Email changed."
        } catch ProfileClientError.incorrectPassword {
            errorMessage = "That password is incorrect."
        } catch ProfileClientError.duplicateEmail {
            errorMessage = "That email is already in use."
        } catch {
            errorMessage = "Email could not be changed. Check your connection and try again."
        }
    }

    private func accept(_ user: APIUser) {
        profile = user
        displayName = user.displayName
        onProfileChanged(user)
    }

    private func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }
}

struct SettingsView: View {
    @State private var model: SettingsModel
    private let social: SocialStore
    private let onSignOut: () -> Void

    init(
        api: TrackerAPIClient,
        token: String,
        user: APIUser,
        social: SocialStore,
        onProfileChanged: @escaping (APIUser) -> Void,
        onSignOut: @escaping () -> Void
    ) {
        _model = State(initialValue: SettingsModel(api: api, token: token, user: user, onProfileChanged: onProfileChanged))
        self.social = social
        self.onSignOut = onSignOut
    }

    var body: some View {
        Form {
            Section("Display name") {
                TextField("Display name", text: $model.displayName)
                    .textContentType(.name)
                    .submitLabel(.done)
                Button(model.isSavingName ? "Saving" : "Save display name") {
                    Task { await model.saveDisplayName() }
                }
                .disabled(model.isSavingName)
            }

            Section {
                LabeledContent("Current", value: model.profile.email)
                TextField("New email", text: $model.newEmail)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Current password", text: $model.currentPassword)
                    .textContentType(.password)
                Button(model.isSavingEmail ? "Changing" : "Change email") {
                    Task { await model.changeEmail() }
                }
                .disabled(!model.canChangeEmail)
            } header: {
                Text("Email")
            } footer: {
                Text("Enter your current password to confirm the change.")
            }

            PrivacySection(social: social)

            if let successMessage = model.successMessage {
                Section {
                    StatusBanner(kind: .success, message: successMessage)
                }
            }
            if let errorMessage = model.errorMessage {
                Section {
                    StatusBanner(kind: .error, message: errorMessage)
                }
            }

            Section {
                Button("Sign out", role: .destructive, action: onSignOut)
            }
        }
        .navigationTitle("Settings")
    }
}

/// Whether new followers need approval.
private struct PrivacySection: View {
    let social: SocialStore
    /// The value being saved, shown while the server confirms so the switch doesn't snap back.
    @State private var pendingValue: Bool?
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Toggle("Private account", isOn: Binding(
                get: { pendingValue ?? social.summary?.isPrivate ?? false },
                set: { isPrivate in
                    guard pendingValue == nil else { return }
                    pendingValue = isPrivate
                    Task {
                        defer { pendingValue = nil }
                        do {
                            try await social.setPrivateAccount(isPrivate)
                            errorMessage = nil
                        } catch {
                            errorMessage = "Your privacy setting could not be saved. Try again."
                        }
                    }
                }
            ))
            .disabled(social.summary == nil || pendingValue != nil)
            if let errorMessage {
                StatusBanner(kind: .error, message: errorMessage)
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("When your account is private, new followers need your approval before they see your activity. People who already follow you keep following. Turning this off approves any waiting requests.")
        }
        .task { await social.refresh() }
    }
}
