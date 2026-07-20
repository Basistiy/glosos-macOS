//
//  AuthModels.swift
//  glosos-macOS
//
//  Created by Antigravity on 6/9/26.
//

import Foundation

public struct AuthUser: Codable, Equatable, Sendable {
    public let id: Int
    public let username: String

    public init(id: Int, username: String) {
        self.id = id
        self.username = username
    }
}

public struct AuthResponse: Codable, Equatable, Sendable {
    public let message: String
    public let token: String
    public let refreshToken: String?
    public let user: AuthUser

    public init(message: String, token: String, refreshToken: String?, user: AuthUser) {
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

    public init(error: String) {
        self.error = error
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
