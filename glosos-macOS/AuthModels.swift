//
//  AuthModels.swift
//  glosos-macOS
//
//  Created by Antigravity on 6/9/26.
//

import Foundation

public struct AuthUser: Codable, Equatable {
    public let id: Int
    public let username: String

    public init(id: Int, username: String) {
        self.id = id
        self.username = username
    }
}

public struct AuthResponse: Codable, Equatable {
    public let message: String
    public let token: String
    public let user: AuthUser

    public init(message: String, token: String, user: AuthUser) {
        self.message = message
        self.token = token
        self.user = user
    }
}

public struct AuthErrorResponse: Codable, Equatable {
    public let error: String

    public init(error: String) {
        self.error = error
    }
}
