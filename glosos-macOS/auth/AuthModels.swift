//
//  AuthModels.swift
//  glosos-macOS
//
//  Created by Antigravity on 6/9/26.
//

import Foundation
import Security

public struct AuthUser: Codable, Equatable, Sendable {
    public let id: Int
    public let username: String
    public let email: String?

    public init(id: Int, username: String, email: String? = nil) {
        self.id = id
        self.username = username
        self.email = email
    }
}

public struct AuthResponse: Codable, Equatable, Sendable {
    public let message: String
    public let token: String
    public let refreshToken: String?
    public let user: AuthUser

    public init(message: String, token: String, refreshToken: String? = nil, user: AuthUser) {
        self.message = message
        self.token = token
        self.refreshToken = refreshToken
        self.user = user
    }
}

public struct RefreshResponse: Codable, Equatable, Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

public struct AuthErrorResponse: Codable, Equatable, Sendable {
    public let error: String
    public let requiresVerification: Bool?
    public let email: String?

    public init(error: String, requiresVerification: Bool? = nil, email: String? = nil) {
        self.error = error
        self.requiresVerification = requiresVerification
        self.email = email
    }
}

public struct GenericMessageResponse: Codable, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public struct EmailLoginRequest: Codable, Equatable, Sendable {
    public let login: String
    public let password: String

    public init(login: String, password: String) {
        self.login = login
        self.password = password
    }
}

public struct VerifyEmailRequest: Codable, Equatable, Sendable {
    public let email: String
    public let otp: String

    public init(email: String, otp: String) {
        self.email = email
        self.otp = otp
    }
}

public struct ResendOTPRequest: Codable, Equatable, Sendable {
    public let email: String

    public init(email: String) {
        self.email = email
    }
}

public struct AppleAuthRequest: Codable, Equatable, Sendable {
    public let identityToken: String
    public let authorizationCode: String?
    public let userIdentifier: String
    public let firstName: String?
    public let lastName: String?
    public let email: String?

    public init(
        identityToken: String,
        authorizationCode: String?,
        userIdentifier: String,
        firstName: String?,
        lastName: String?,
        email: String?
    ) {
        self.identityToken = identityToken
        self.authorizationCode = authorizationCode
        self.userIdentifier = userIdentifier
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
    }
}

public enum LoginResult: Equatable, Sendable {
    case success
    case requiresVerification(email: String)
    case failure(String)
}

// MARK: - Token Storage Protocol & Implementations

public protocol TokenStoring: Sendable {
    @discardableResult
    func save(token: String, account: String) -> Bool
    func get(account: String) -> String?
    @discardableResult
    func delete(account: String) -> Bool
}

public struct KeychainTokenStore: TokenStoring {
    public let service: String

    public init(service: String = "com.glosos.auth-token") {
        self.service = service
    }

    @discardableResult
    public func save(token: String, account: String) -> Bool {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    public func get(account: String) -> String? {
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
    public func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }
}

public final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init(initial: [String: String] = [:]) {
        self.storage = initial
    }

    @discardableResult
    public func save(token: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = token
        return true
    }

    public func get(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    @discardableResult
    public func delete(account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: account)
        return true
    }
}
