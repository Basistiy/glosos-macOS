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
    static let service = "com.glosos.auth-token"

    @discardableResult
    public static func save(token: String, account: String) -> Bool {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        // Delete any existing item first to prevent conflicts
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    public static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    @discardableResult
    public static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }
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
    
    private static let signalingAPIEndpointKey = "signalingAPIEndpoint"
    private static let currentUserInfoKey = "currentUserInfo"
    private static let tokenAccountKey = "current_user_token"
    private static let refreshTokenAccountKey = "current_user_refresh_token"

    nonisolated(unsafe) private var tokenExpiredObserver: Any?
    private let presentationContextProvider = PresentationContextProvider()

    public init(userDefaults: UserDefaults = .standard, urlSession: URLSession = .shared) {
        self.userDefaults = userDefaults
        self.urlSession = urlSession

        // Load signaling endpoint, default to https://glosos.com/api
        self.signalingAPIEndpoint = userDefaults.string(forKey: Self.signalingAPIEndpointKey)
            ?? "https://glosos.com/api"

        restoreSession()

        self.tokenExpiredObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("GlososAuthTokenExpired"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[AuthManager] Auth token expired or invalid. Attempting token refresh...")
            guard let self = self else { return }
            Task { @MainActor in
                let success = await self.refreshAccessToken()
                if !success {
                    print("[AuthManager] Token refresh failed. Logging out...")
                    self.logout()
                    self.error = "Session expired. Please log in again."
                } else {
                    print("[AuthManager] Token refreshed successfully.")
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

    public func restoreSession() {
        // Load user from UserDefaults
        if let data = userDefaults.data(forKey: Self.currentUserInfoKey),
           let decodedUser = try? JSONDecoder().decode(AuthUser.self, from: data) {
            self.user = decodedUser
        }

        // Load refresh token from Keychain
        if let storedRefreshToken = KeychainHelper.get(account: Self.refreshTokenAccountKey) {
            self.refreshToken = storedRefreshToken
        } else {
            self.refreshToken = nil
        }

        // Load token from Keychain
        if let storedToken = KeychainHelper.get(account: Self.tokenAccountKey) {
            self.token = storedToken
            
            // Check if expired and refresh asynchronously
            if isTokenExpired(storedToken) {
                Task {
                    _ = await refreshAccessToken()
                }
            }
        } else {
            // Clear both if token is missing
            self.token = nil
            self.user = nil
        }
    }

    @discardableResult
    public func refreshAccessToken() async -> Bool {
        guard let storedRefreshToken = KeychainHelper.get(account: Self.refreshTokenAccountKey) else {
            print("[AuthManager] No stored refresh token found.")
            return false
        }

        guard var endpointUrl = URL(string: signalingAPIEndpoint) else {
            print("[AuthManager] Invalid API Endpoint URL for refresh")
            return false
        }

        if #available(macOS 13.0, *) {
            endpointUrl = endpointUrl.appending(path: "/auth/refresh")
        } else {
            endpointUrl = endpointUrl.appendingPathComponent("/auth/refresh")
        }

        var request = URLRequest(url: endpointUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["refreshToken": storedRefreshToken]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            return false
        }
        request.httpBody = httpBody

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }

            if (200..<300).contains(httpResponse.statusCode) {
                let refreshResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)

                // Save new access token to Keychain
                KeychainHelper.save(token: refreshResponse.token, account: Self.tokenAccountKey)

                self.token = refreshResponse.token
                return true
            } else {
                print("[AuthManager] Refresh token request failed with status code \(httpResponse.statusCode)")
                return false
            }
        } catch {
            print("[AuthManager] Network error during refresh: \(error.localizedDescription)")
            return false
        }
    }

    public func login(username: String, password: String) async -> Bool {
        await performAuthRequest(
            path: "/auth/login",
            username: username,
            password: password
        )
    }

    public func register(username: String, password: String) async -> Bool {
        await performAuthRequest(
            path: "/auth/register",
            username: username,
            password: password
        )
    }

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

        guard var endpointUrl = URL(string: signalingAPIEndpoint) else {
            self.error = "Invalid API Endpoint URL"
            self.isLoading = false
            return false
        }
        
        if #available(macOS 13.0, *) {
            endpointUrl = endpointUrl.appending(path: "/auth/apple")
        } else {
            endpointUrl = endpointUrl.appendingPathComponent("/auth/apple")
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

                // Save user to UserDefaults
                if let userData = try? JSONEncoder().encode(authResponse.user) {
                    userDefaults.set(userData, forKey: Self.currentUserInfoKey)
                }

                // Save token to Keychain
                KeychainHelper.save(token: authResponse.token, account: Self.tokenAccountKey)
                if let rToken = authResponse.refreshToken {
                    KeychainHelper.save(token: rToken, account: Self.refreshTokenAccountKey)
                    self.refreshToken = rToken
                }

                self.user = authResponse.user
                self.token = authResponse.token
                self.isLoading = false
                return true
            } else {
                if let errorResponse = try? JSONDecoder().decode(AuthErrorResponse.self, from: data) {
                    self.error = errorResponse.error
                } else {
                    self.error = "Request failed with status code \(httpResponse.statusCode)"
                }
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
        if let storedRefreshToken = KeychainHelper.get(account: Self.refreshTokenAccountKey),
           var endpointUrl = URL(string: signalingAPIEndpoint) {
            if #available(macOS 13.0, *) {
                endpointUrl = endpointUrl.appending(path: "/auth/logout")
            } else {
                endpointUrl = endpointUrl.appendingPathComponent("/auth/logout")
            }
            
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
        KeychainHelper.delete(account: Self.tokenAccountKey)
        KeychainHelper.delete(account: Self.refreshTokenAccountKey)
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
        let username = queryItems.first(where: { $0.name == "username" })?.value ?? "Google User"
        let refreshToken = queryItems.first(where: { $0.name == "refreshToken" })?.value
        
        let authUser = AuthUser(id: id, username: username)
        
        // Save user to UserDefaults
        if let userData = try? JSONEncoder().encode(authUser) {
            userDefaults.set(userData, forKey: Self.currentUserInfoKey)
        }
        
        // Save token to Keychain
        KeychainHelper.save(token: token, account: Self.tokenAccountKey)
        if let rToken = refreshToken {
            KeychainHelper.save(token: rToken, account: Self.refreshTokenAccountKey)
            self.refreshToken = rToken
        }
        
        self.user = authUser
        self.token = token
    }

    private func performAuthRequest(path: String, username: String, password: String) async -> Bool {
        isLoading = true
        error = nil

        guard var endpointUrl = URL(string: signalingAPIEndpoint) else {
            self.error = "Invalid API Endpoint URL"
            self.isLoading = false
            return false
        }
        
        // Append path component properly
        if #available(macOS 13.0, *) {
            endpointUrl = endpointUrl.appending(path: path)
        } else {
            endpointUrl = endpointUrl.appendingPathComponent(path)
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

                // Save user to UserDefaults
                if let userData = try? JSONEncoder().encode(authResponse.user) {
                    userDefaults.set(userData, forKey: Self.currentUserInfoKey)
                }

                // Save token to Keychain
                KeychainHelper.save(token: authResponse.token, account: Self.tokenAccountKey)
                if let rToken = authResponse.refreshToken {
                    KeychainHelper.save(token: rToken, account: Self.refreshTokenAccountKey)
                    self.refreshToken = rToken
                }

                self.user = authResponse.user
                self.token = authResponse.token
                self.isLoading = false
                return true
            } else {
                // Try to parse error message from server
                if let errorResponse = try? JSONDecoder().decode(AuthErrorResponse.self, from: data) {
                    self.error = errorResponse.error
                } else {
                    self.error = "Request failed with status code \(httpResponse.statusCode)"
                }
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



