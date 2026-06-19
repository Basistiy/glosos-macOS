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
public struct KeychainHelper {
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
    @Published public var error: String?
    @Published public var isLoading = false
    @Published public var signalingAPIEndpoint: String

    private let userDefaults: UserDefaults
    private let urlSession: URLSession
    
    private static let signalingAPIEndpointKey = "signalingAPIEndpoint"
    private static let currentUserInfoKey = "currentUserInfo"
    private static let tokenAccountKey = "current_user_token"

    private var tokenExpiredObserver: Any?
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
            guard let self = self else { return }
            print("[AuthManager] Auth token expired or invalid. Logging out...")
            self.logout()
            self.error = "Session expired. Please log in again."
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

        // Load token from Keychain
        if let storedToken = KeychainHelper.get(account: Self.tokenAccountKey) {
            self.token = storedToken
        } else {
            // Clear both if token is missing
            self.token = nil
            self.user = nil
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
        self.user = nil
        self.token = nil
        self.error = nil
        userDefaults.removeObject(forKey: Self.currentUserInfoKey)
        KeychainHelper.delete(account: Self.tokenAccountKey)
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
        ) { [weak self] callbackURL, error in
            guard let self = self else { return }
            
            Task { @MainActor in
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
        
        let authUser = AuthUser(id: id, username: username)
        
        // Save user to UserDefaults
        if let userData = try? JSONEncoder().encode(authUser) {
            userDefaults.set(userData, forKey: Self.currentUserInfoKey)
        }
        
        // Save token to Keychain
        KeychainHelper.save(token: token, account: Self.tokenAccountKey)
        
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


