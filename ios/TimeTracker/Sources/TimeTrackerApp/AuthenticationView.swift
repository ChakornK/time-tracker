import SwiftUI

struct AuthenticationView: View {
    let session: AuthSession
    @State private var isRegistering = false
    @State private var username = ""
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if isRegistering {
                        TextField("Display name (optional)", text: $displayName)
                            .textContentType(.name)
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    SecureField("Password", text: $password)
                        .textContentType(isRegistering ? .newPassword : .password)
                    if isRegistering {
                        Text("Use an email like name@gmail.com. Your display name defaults to your username.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if !isRegistering {
                        Button("Sign in") {
                            Task { await session.login(username: username, password: password) }
                        }
                        .disabled(session.isLoading)
                    }
                    Button(isRegistering ? "I already have an account" : "Create an account") {
                        isRegistering.toggle()
                    }
                    .font(.footnote)
                }

                if session.isLoading {
                    ProgressView("Connecting")
                }
                if let errorMessage = session.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: [username, displayName, email, password]) {
                session.errorMessage = nil
            }
            .onChange(of: isRegistering) {
                session.errorMessage = nil
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isRegistering {
                    createAccountButton
                }
            }
            .navigationTitle(isRegistering ? "Create account" : "Welcome back")
        }
    }

    private var createAccountButton: some View {
        Button {
            Task {
                await session.register(username: username, displayName: displayName, email: email, password: password)
            }
        } label: {
            Group {
                if session.isLoading {
                    ProgressView("Creating account")
                } else {
                    Text("Create account")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .primaryActionStyle()
        .disabled(session.isLoading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
