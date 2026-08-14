//
//  AuthManager.swift
//  glosos-macOS
//
//  Created by Antigravity on 6/9/26.
//

import Foundation
import Combine
import Security
import AppKit
import AuthenticationServices

/// A helper class to securely store the JWT token in the macOS Keychain.
public struct KeychainHelper: Sendable {
    private static let store = KeychainTokenStore()

    @discardableResult
    public static func save(token: String, account: String) -> Bool {
        store.save(token: token, account: account)
    }

    public static func get(account: String) -> String? {
        store.get(account: account)
    }

    @discardableResult
    public static func delete(account: String) -> Bool {
        store.delete(account: account)
    }
}

public enum RefreshResult: Equatable, Sendable {
    case success
    case invalidToken
    case networkError
}

@MainActor
public final class AuthManager: ObservableObject {
    @Published public var user: AuthUser?
    @Published public var token: String?
    @Published public var refreshToken: String?
    @Published public var error: String?
    @Published public var isLoading = false
    @Published public var signalingAPIEndpoint: String

    private let userDefaults: UserDefaults
    private let urlSession: URLSession
    private let tokenStore: TokenStoring
    
    private static let signalingAPIEndpointKey = "signalingAPIEndpoint"
    private static let currentUserInfoKey = "currentUserInfo"
    private static let tokenAccountKey = "current_user_token"
    private static let refreshTokenAccountKey = "current_user_refresh_token"

    nonisolated(unsafe) private var tokenExpiredObserver: Any?
    private let presentationContextProvider = PresentationContextProvider()

    public init(
        userDefaults: UserDefaults = .standard,
        urlSession: URLSession = .shared,
        tokenStore: TokenStoring = KeychainTokenStore(),
        autoRestoreSession: Bool = true
    ) {
        self.userDefaults = userDefaults
        self.urlSession = urlSession
        self.tokenStore = tokenStore

        // Load signaling endpoint, default to https://glosos.com/api
        self.signalingAPIEndpoint = userDefaults.string(forKey: Self.signalingAPIEndpointKey)
            ?? "https://glosos.com/api"

        if autoRestoreSession {
            restoreSession()
        }

        self.tokenExpiredObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("GlososAuthTokenExpired"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[AuthManager] Auth token expired or invalid. Attempting token refresh...")
            guard let self = self else { return }
            Task { @MainActor in
                let result = await self.refreshAccessTokenDetailed()
                switch result {
                case .success:
                    print("[AuthManager] Token refreshed successfully.")
                case .invalidToken:
                    print("[AuthManager] Refresh token is invalid or expired. Logging out...")
                    self.logout()
                    self.error = "Session expired. Please log in again."
                case .networkError:
                    print("[AuthManager] Network error during token refresh. Session preserved, will retry when network is restored.")
                }
            }
        }
    }

    deinit {
        if let observer = tokenExpiredObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func saveSignalingAPIEndpoint(_ endpoint: String) {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            self.signalingAPIEndpoint = trimmed
            userDefaults.set(trimmed, forKey: Self.signalingAPIEndpointKey)
        }
    }

    private var isRefreshingToken = false

    public func restoreSession() {
        // Load user from UserDefaults
        if let data = userDefaults.data(forKey: Self.currentUserInfoKey),
           let decodedUser = try? JSONDecoder().decode(AuthUser.self, from: data) {
            self.user = decodedUser
        }

        // Load refresh token from Token Store
        if let storedRefreshToken = tokenStore.get(account: Self.refreshTokenAccountKey) {
            self.refreshToken = storedRefreshToken
        } else {
            self.refreshToken = nil
        }

        // Load token from Token Store
        if let storedToken = tokenStore.get(account: Self.tokenAccountKey) {
            // Check if expired and refresh asynchronously before assigning self.token
            if isTokenExpired(storedToken) {
                Task {
                    let result = await self.refreshAccessTokenDetailed()
                    if result == .invalidToken {
                        print("[AuthManager] Stored token expired and refresh failed. Logging out...")
                        self.logout()
                    } else if result == .networkError {
                        self.token = storedToken
                    }
                }
            } else {
                self.token = storedToken
            }
        } else {
            // Clear both if token is missing
            self.token = nil
            self.user = nil
        }
    }

    private func makeURL(path: String) -> URL? {
        guard let base = URL(string: signalingAPIEndpoint) else { return nil }
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if #available(macOS 13.0, *) {
            return base.appending(path: cleanPath)
        } else {
            return base.appendingPathComponent(cleanPath)
        }
    }

    @discardableResult
    public func refreshAccessTokenDetailed() async -> RefreshResult {
        guard !isRefreshingToken else {
            print("[AuthManager] Token refresh already in progress. Skipping duplicate request.")
            return .networkError
        }
        isRefreshingToken = true
        defer { isRefreshingToken = false }

        guard let storedRefreshToken = tokenStore.get(account: Self.refreshTokenAccountKey) else {
            print("[AuthManager] No stored refresh token found.")
            return .invalidToken
        }

        guard let endpointUrl = makeURL(path: "auth/refresh") else {
            print("[AuthManager] Invalid API Endpoint URL for refresh")
            return .invalidToken
        }

        var request = URLRequest(url: endpointUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["refreshToken": storedRefreshToken]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            return .invalidToken
        }
        request.httpBody = httpBody

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkError
            }

            if (200..<300).contains(httpResponse.statusCode) {
                let refreshResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)

                // Save new access token
                tokenStore.save(token: refreshResponse.token, account: Self.tokenAccountKey)

                self.token = refreshResponse.token
                return .success
            } else if (400..<500).contains(httpResponse.statusCode) {
                print("[AuthManager] Refresh token request rejected with status code \(httpResponse.statusCode)")
                return .invalidToken
            } else {
                print("[AuthManager] Refresh token request failed with server status code \(httpResponse.statusCode)")
                return .networkError
            }
        } catch {
            print("[AuthManager] Network error during refresh: \(error.localizedDescription)")
            return .networkError
        }
    }

    @discardableResult
    public func refreshAccessToken() async -> Bool {
        let result = await refreshAccessTokenDetailed()
        return result == .success
    }

    // MARK: - Email Log In

    @discardableResult
    public func loginWithEmail(identifier: String, password: String) async -> LoginResult {
        isLoading = true
        error = nil

        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedIdentifier.isEmpty || password.isEmpty {
            let msg = "Email/username and password are required"
            self.error = msg
            self.isLoading = false
            return .failure(msg)
        }

        guard let endpointUrl = makeURL(path: "auth/login") else {
            let msg = "Invalid API Endpoint URL"
            self.error = msg
            self.isLoading = false
            return .failure(msg)
        }

        var request = URLRequest(url: endpointUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody = EmailLoginRequest(login: trimmedIdentifier, password: password)
        guard let httpBody = try? JSONEncoder().encode(requestBody) else {
            let msg = "Failed to encode request parameters"
            self.error = msg
            self.isLoading = false
            return .failure(msg)
        }
        request.httpBody = httpBody

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                let msg = "Invalid server response"
                self.error = msg
                self.isLoading = false
                return .failure(msg)
            }

            if (200..<300).contains(httpResponse.statusCode) {
                let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                self.persistSession(authResponse: authResponse)
                self.isLoading = false
                return .success
            } else if httpResponse.statusCode == 403 {
                // Check if email verification is required
                if let errorResponse = try? JSONDecoder().decode(AuthErrorResponse.self, from: data),
                   errorResponse.requiresVerification == true {
                    let targetEmail = errorResponse.email ?? trimmedIdentifier
                    self.isLoading = false
                    return .requiresVerification(email: targetEmail)
                }

                let errorMsg = self.parseErrorMessage(from: data, fallback: "Email verification required")
                self.error = errorMsg
                self.isLoading = false
                return .failure(errorMsg)
            } else {
                let errorMsg = self.parseErrorMessage(from: data, fallback: "Login failed with status code \(httpResponse.statusCode)")
                self.error = errorMsg
                self.isLoading = false
                return .failure(errorMsg)
            }
        } catch {
            let msg = "Network error: \(error.localizedDescription)"
            self.error = msg
            self.isLoading = false
            return .failure(msg)
        }
    }

    // MARK: - Email Verification (OTP)

    @discardableResult
    public func verifyEmailOTP(email: String, otp: String) async -> Bool {
        isLoading = true
        error = nil

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedOtp = otp.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEmail.isEmpty, !trimmedOtp.isEmpty else {
            self.error = "Email and 6-digit verification code are required"
            self.isLoading = false
            return false
        }

        guard let endpointUrl = makeURL(path: "auth/verify-email") else {
            self.error = "Invalid API Endpoint URL"
            self.isLoading = false
            return false
        }

        var request = URLRequest(url: endpointUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody = VerifyEmailRequest(email: trimmedEmail, otp: trimmedOtp)
        guard let httpBody = try? JSONEncoder().encode(requestBody) else {
            self.error = "Failed to encode verification request"
            self.isLoading = false
            return false
        }
        request.httpBody = httpBody

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                self.error = "Invalid server response"
                self.isLoading = false
                return false
            }

            if (200..<300).contains(httpResponse.statusCode) {
                let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                self.persistSession(authResponse: authResponse)
                self.isLoading = false
                return true
            } else {
                let errorMsg = self.parseErrorMessage(from: data, fallback: "Verification failed")
                self.error = errorMsg
                self.isLoading = false
                return false
            }
        } catch {
            self.error = "Network error: \(error.localizedDescription)"
            self.isLoading = false
            return false
        }
    }

    @discardableResult
    public func resendOTP(email: String) async -> (success: Bool, message: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedEmail.isEmpty else {
            return (false, "Email address is required")
        }

        guard let endpointUrl = makeURL(path: "auth/resend-otp") else {
            return (false, "Invalid API Endpoint URL")
        }

        var request = URLRequest(url: endpointUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody = ResendOTPRequest(email: trimmedEmail)
        guard let httpBody = try? JSONEncoder().encode(requestBody) else {
            return (false, "Failed to encode resend request")
        }
        request.httpBody = httpBody

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "Invalid server response")
            }

            if (200..<300).contains(httpResponse.statusCode) {
                let msg = (try? JSONDecoder().decode(GenericMessageResponse.self, from: data))?.message
                    ?? "Verification code resent successfully. Please check your email."
                return (true, msg)
            } else {
                let errorMsg = self.parseErrorMessage(from: data, fallback: "Failed to resend code")
                return (false, errorMsg)
            }
        } catch {
            return (false, "Network error: \(error.localizedDescription)")
        }
    }

    // MARK: - Legacy / Username Login Forwarding

    public func login(username: String, password: String) async -> Bool {
        let result = await loginWithEmail(identifier: username, password: password)
        switch result {
        case .success:
            return true
        case .requiresVerification:
            self.error = "Email verification required"
            return false
        case .failure:
            return false
        }
    }

    public func register(username: String, password: String) async -> Bool {
        await performAuthRequest(
            path: "auth/register",
            username: username,
            password: password
        )
    }

    // MARK: - Apple Authentication

    public func loginWithApple(
        identityToken: String,
        authorizationCode: String?,
        userIdentifier: String,
        firstName: String?,
        lastName: String?,
        email: String?
    ) async -> Bool {
        isLoading = true
        error = nil

        guard let endpointUrl = makeURL(path: "auth/apple") else {
            self.error = "Invalid API Endpoint URL"
            self.isLoading = false
            return false
        }

        var request = URLRequest(url: endpointUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody = AppleAuthRequest(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            userIdentifier: userIdentifier,
            firstName: firstName,
            lastName: lastName,
            email: email
        )

        guard let httpBody = try? JSONEncoder().encode(requestBody) else {
            self.error = "Failed to encode request parameters"
            self.isLoading = false
            return false
        }
        request.httpBody = httpBody

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                self.error = "Invalid server response"
                self.isLoading = false
                return false
            }

            if (200..<300).contains(httpResponse.statusCode) {
                let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                self.persistSession(authResponse: authResponse)
                self.isLoading = false
                return true
            } else {
                let errorMsg = self.parseErrorMessage(from: data, fallback: "Request failed with status code \(httpResponse.statusCode)")
                self.error = errorMsg
                self.isLoading = false
                return false
            }
        } catch {
            self.error = "Network error: \(error.localizedDescription)"
            self.isLoading = false
            return false
        }
    }

    public func logout() {
        // Send logout request to backend in the background to revoke the refresh token
        if let storedRefreshToken = tokenStore.get(account: Self.refreshTokenAccountKey),
           let endpointUrl = makeURL(path: "auth/logout") {
            var request = URLRequest(url: endpointUrl)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let body: [String: String] = ["refreshToken": storedRefreshToken]
            if let httpBody = try? JSONSerialization.data(withJSONObject: body) {
                request.httpBody = httpBody
                
                // Fire and forget logout API call
                Task {
                    try? await urlSession.data(for: request)
                }
            }
        }

        self.user = nil
        self.token = nil
        self.refreshToken = nil
        self.error = nil
        userDefaults.removeObject(forKey: Self.currentUserInfoKey)
        tokenStore.delete(account: Self.tokenAccountKey)
        tokenStore.delete(account: Self.refreshTokenAccountKey)
    }

    public func clearError() {
        self.error = nil
    }

    public func startAppleWebAuth() {
        self.isLoading = true
        self.error = nil
        
        let clientID = "com.glosos.glososmacos.signin"
        let redirectURI = "https://glosos.com/api/auth/apple/callback"
        
        guard let url = URL(string: "https://appleid.apple.com/auth/authorize?client_id=\(clientID)&redirect_uri=\(redirectURI)&response_type=code%20id_token&scope=name%20email&response_mode=form_post&state=app_macos") else {
            self.error = "Invalid OAuth URL"
            self.isLoading = false
            return
        }
        
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "glosos"
        ) { @Sendable [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self = self else { return }
                self.isLoading = false
                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionErrorDomain && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        return
                    }
                    self.error = error.localizedDescription
                    return
                }
                
                guard let callbackURL = callbackURL else {
                    self.error = "Authentication failed: No callback URL"
                    return
                }
                
                self.handleWebAuthCallback(url: callbackURL)
            }
        }
        
        session.presentationContextProvider = self.presentationContextProvider
        session.start()
    }
    
    private func handleWebAuthCallback(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let queryItems = components.queryItems else {
            self.error = "Invalid callback URL format"
            return
        }
        
        guard let token = queryItems.first(where: { $0.name == "token" })?.value else {
            self.error = "Authentication failed: Missing token in server callback"
            return
        }
        
        let idString = queryItems.first(where: { $0.name == "id" })?.value ?? "0"
        let id = Int(idString) ?? 0
        let username = queryItems.first(where: { $0.name == "username" })?.value ?? "Apple User"
        let refreshToken = queryItems.first(where: { $0.name == "refreshToken" })?.value
        
        let authUser = AuthUser(id: id, username: username)
        
        // Save user to UserDefaults
        if let userData = try? JSONEncoder().encode(authUser) {
            userDefaults.set(userData, forKey: Self.currentUserInfoKey)
        }
        
        // Save token to tokenStore
        tokenStore.save(token: token, account: Self.tokenAccountKey)
        if let rToken = refreshToken {
            tokenStore.save(token: rToken, account: Self.refreshTokenAccountKey)
            self.refreshToken = rToken
        }
        
        self.user = authUser
        self.token = token
    }

    private func persistSession(authResponse: AuthResponse) {
        // Save user to UserDefaults
        if let userData = try? JSONEncoder().encode(authResponse.user) {
            userDefaults.set(userData, forKey: Self.currentUserInfoKey)
        }

        // Save token to tokenStore
        tokenStore.save(token: authResponse.token, account: Self.tokenAccountKey)
        if let rToken = authResponse.refreshToken {
            tokenStore.save(token: rToken, account: Self.refreshTokenAccountKey)
            self.refreshToken = rToken
        }

        self.user = authResponse.user
        self.token = authResponse.token
    }

    private func parseErrorMessage(from data: Data, fallback: String) -> String {
        if let errorResponse = try? JSONDecoder().decode(AuthErrorResponse.self, from: data) {
            return errorResponse.error
        }
        return fallback
    }

    private func performAuthRequest(path: String, username: String, password: String) async -> Bool {
        isLoading = true
        error = nil

        guard let endpointUrl = makeURL(path: path) else {
            self.error = "Invalid API Endpoint URL"
            self.isLoading = false
            return false
        }

        var request = URLRequest(url: endpointUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["username": username, "password": password]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            self.error = "Failed to encode request parameters"
            self.isLoading = false
            return false
        }
        request.httpBody = httpBody

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                self.error = "Invalid server response"
                self.isLoading = false
                return false
            }

            if (200..<300).contains(httpResponse.statusCode) {
                let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                self.persistSession(authResponse: authResponse)
                self.isLoading = false
                return true
            } else {
                let errorMsg = self.parseErrorMessage(from: data, fallback: "Request failed with status code \(httpResponse.statusCode)")
                self.error = errorMsg
                self.isLoading = false
                return false
            }
        } catch {
            self.error = "Network error: \(error.localizedDescription)"
            self.isLoading = false
            return false
        }
    }
}

@MainActor
class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return NSApplication.shared.windows.first ?? NSWindow()
    }
}

// MARK: - JWT Decoder Helpers
nonisolated private struct JWTPayload: Codable {
    let exp: Double?
}

nonisolated private func isTokenExpired(_ token: String) -> Bool {
    let parts = token.components(separatedBy: ".")
    guard parts.count == 3 else { return true }
    
    var base64 = parts[1]
    let remainder = base64.count % 4
    if remainder > 0 {
        base64 += String(repeating: "=", count: 4 - remainder)
    }
    
    // Replace URL-safe base64 characters
    base64 = base64.replacingOccurrences(of: "-", with: "+")
    base64 = base64.replacingOccurrences(of: "_", with: "/")
    
    guard let data = Data(base64Encoded: base64) else { return true }
    guard let payload = try? JSONDecoder().decode(JWTPayload.self, from: data) else { return true }
    guard let exp = payload.exp else { return false }
    
    let expirationDate = Date(timeIntervalSince1970: exp)
    return expirationDate < Date(timeIntervalSinceNow: 30) // Expired or expiring within 30 seconds
}
