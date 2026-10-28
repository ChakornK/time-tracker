import SwiftUI
import WidgetKit

@MainActor
@Observable
final class AuthSession {
    let api: TrackerAPIClient
    private let tokenStore: any TokenStore
    private let liveActivity: LiveActivityController
    private(set) var accessToken: String?
    private(set) var user: APIUser?
    private(set) var isLoading = false
    var errorMessage: String?

    init(api: TrackerAPIClient, tokenStore: any TokenStore, liveActivity: LiveActivityController) {
        self.api = api
        self.tokenStore = tokenStore
        self.liveActivity = liveActivity
        do {
            accessToken = try tokenStore.read()
        } catch {
            errorMessage = "Could not read the saved session. Sign in again."
        }
    }

    func login(username: String, password: String) async {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            errorMessage = "Enter your username and password."
            return
        }
        await authenticate {
            let tokens = try await api.login(username: username, password: password)
            try await accept(tokens.accessToken)
        }
    }

    func register(username: String, displayName: String, email: String, password: String) async {
        let problems = AccountValidation.registrationProblems(username: username, email: email, password: password)
        guard problems.isEmpty else {
            errorMessage = problems.joined(separator: "\n")
            return
        }
        await authenticate {
            _ = try await api.register(username: username, displayName: displayName, email: email, password: password)
            let tokens = try await api.login(username: username, password: password)
            try await accept(tokens.accessToken)
        }
    }

    func updateUser(_ user: APIUser) {
        self.user = user
    }

    /// Loads the profile for a token restored from the keychain. Only a rejected token signs the user out;
    /// network failures leave the session in place so the user can retry.
    func restoreSession() async {
        guard let accessToken else { return }
        errorMessage = nil
        do {
            user = try await api.profile(accessToken: accessToken)
        } catch let error as APIClientError where error.isUnauthorized {
            expireSession()
        } catch {
            errorMessage = "Could not reach the server. Check your connection and try again."
        }
    }

    func expireSession() {
        signOut()
        errorMessage = "Your session expired. Sign in again."
    }

    func signOut() {
        Task { await liveActivity.endAll() }
        WidgetSummaryStorage.clearActiveUser(from: WidgetSummaryStorage.sharedDefaults)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSummaryStorage.widgetKind)
        do {
            try tokenStore.delete()
            accessToken = nil
            user = nil
            errorMessage = nil
        } catch {
            errorMessage = "Could not sign out: \(error.localizedDescription)"
        }
    }

    private func accept(_ token: String) async throws {
        do {
            let user = try await api.profile(accessToken: token)
            try tokenStore.save(token)
            accessToken = token
            self.user = user
        } catch {
            try? tokenStore.delete()
            accessToken = nil
            user = nil
            throw error
        }
    }

    private func authenticate(_ operation: () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await operation()
        } catch let error as APIClientError {
            errorMessage = switch error {
            case .server(_, "INVALID_CREDENTIALS"):
                "Username or password is incorrect."
            case .invalidFields(let messages):
                messages.joined(separator: "\n")
            case .server(_, "INVALID_REQUEST"):
                "Some fields are invalid. Check them and try again."
            case .server(409, _):
                "That username or email is already in use."
            case .server(let statusCode, _) where statusCode >= 500:
                "The server could not complete the request (error \(statusCode)). It may be unable to reach its database; try again shortly."
            case .server(let statusCode, let code):
                "Request failed (\(statusCode), \(code)). Check the fields and try again."
            case .invalidRequest, .invalidResponse, .decoding:
                "The server returned an unreadable response."
            }
        } catch {
            errorMessage = "Could not connect. Check your network and try again."
        }
    }
}
