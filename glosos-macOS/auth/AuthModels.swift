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

    private enum CodingKeys: String, CodingKey {
        case message
        case token
        case refreshToken
        case refresh_token
        case user
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.message = try container.decode(String.self, forKey: .message)
        self.token = try container.decode(String.self, forKey: .token)
        self.user = try container.decode(AuthUser.self, forKey: .user)
        
        if let rt = try container.decodeIfPresent(String.self, forKey: .refreshToken) {
            self.refreshToken = rt
        } else if let rtSnake = try container.decodeIfPresent(String.self, forKey: .refresh_token) {
            self.refreshToken = rtSnake
        } else {
            self.refreshToken = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        try container.encode(token, forKey: .token)
        try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try container.encode(user, forKey: .user)
    }
}

public struct RefreshResponse: Codable, Equatable, Sendable {
    public let token: String
    public let refreshToken: String?

    public init(token: String, refreshToken: String? = nil) {
        self.token = token
        self.refreshToken = refreshToken
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case refreshToken
        case refresh_token
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try container.decode(String.self, forKey: .token)
        
        if let rt = try container.decodeIfPresent(String.self, forKey: .refreshToken) {
            self.refreshToken = rt
        } else if let rtSnake = try container.decodeIfPresent(String.self, forKey: .refresh_token) {
            self.refreshToken = rtSnake
        } else {
            self.refreshToken = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
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

// MARK: - Auth State Enums

public enum LoginResult: Equatable, Sendable {
    case success
    case requiresVerification(email: String)
    case failure(String)
}

public enum SignUpResult: Equatable, Sendable {
    case success
    case requiresVerification(email: String)
    case failure(String)
}

public enum VerifyEmailResult: Equatable, Sendable {
    case success
    case failure(String)
}

public enum ResendOTPResult: Equatable, Sendable {
    case success
    case failure(String)
}

public enum PasswordResetRequestResult: Equatable, Sendable {
    case success
    case failure(String)
}

public enum PasswordResetConfirmResult: Equatable, Sendable {
    case success
    case failure(String)
}

public enum ChangePasswordResult: Equatable, Sendable {
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
        
        // 1. Delete any existing item for (service, account)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // 2. Add the new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
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
        return status == errSecSuccess || status == errSecItemNotFound
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
