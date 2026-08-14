//
//  AuthManagerTests.swift
//  glosos-macOSTests
//
//  Created by Antigravity on 6/9/26.
//

import Foundation
import Testing
@testable import Glosos

/// A mock URLProtocol to intercept URLSession network requests in tests
private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: 0, userInfo: [NSLocalizedDescriptionKey: "No handler registered"]))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct AuthManagerTests {

    @Test
    @MainActor
    func loginWithEmailSuccessfulStoresCredentialsAndToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let tokenStore = InMemoryTokenStore()
        let manager = AuthManager(userDefaults: mockDefaults, urlSession: mockSession, tokenStore: tokenStore, autoRestoreSession: false)

        let expectedUser = AuthUser(id: 42, username: "testuser", email: "test@example.com")
        let responsePayload = AuthResponse(
            message: "Login successful",
            token: "valid-jwt-token-xyz",
            refreshToken: "valid-refresh-token-123",
            user: expectedUser
        )
        let responseData = try JSONEncoder().encode(responsePayload)

        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/api/auth/login")
            #expect(request.httpMethod == "POST")

            if let body = request.httpBody, let loginReq = try? JSONDecoder().decode(EmailLoginRequest.self, from: body) {
                #expect(loginReq.login == "test@example.com")
                #expect(loginReq.password == "password123")
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseData)
        }

        let result = await manager.loginWithEmail(identifier: "test@example.com", password: "password123")

        #expect(result == .success)
        #expect(manager.user == expectedUser)
        #expect(manager.token == "valid-jwt-token-xyz")
        #expect(manager.refreshToken == "valid-refresh-token-123")
        #expect(manager.error == nil)

        // Verify storage
        #expect(tokenStore.get(account: "current_user_token") == "valid-jwt-token-xyz")
        #expect(tokenStore.get(account: "current_user_refresh_token") == "valid-refresh-token-123")
        if let storedData = mockDefaults.data(forKey: "currentUserInfo"),
           let storedUser = try? JSONDecoder().decode(AuthUser.self, from: storedData) {
            #expect(storedUser == expectedUser)
        } else {
            Issue.record("User not saved in UserDefaults")
        }
    }

    @Test
    @MainActor
    func loginWithEmailRequiresVerificationReturnsCorrectState() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let tokenStore = InMemoryTokenStore()
        let manager = AuthManager(userDefaults: mockDefaults, urlSession: mockSession, tokenStore: tokenStore, autoRestoreSession: false)

        let errorPayload = AuthErrorResponse(
            error: "Email verification required",
            requiresVerification: true,
            email: "unverified@example.com"
        )
        let responseData = try JSONEncoder().encode(errorPayload)

        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/api/auth/login")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseData)
        }

        let result = await manager.loginWithEmail(identifier: "unverified@example.com", password: "password123")

        #expect(result == .requiresVerification(email: "unverified@example.com"))
        #expect(manager.user == nil)
        #expect(manager.token == nil)
    }

    @Test
    @MainActor
    func loginFailureSetsErrorState() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let tokenStore = InMemoryTokenStore()
        let manager = AuthManager(userDefaults: mockDefaults, urlSession: mockSession, tokenStore: tokenStore, autoRestoreSession: false)

        let errorPayload = AuthErrorResponse(error: "Invalid email/username or password")
        let responseData = try JSONEncoder().encode(errorPayload)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseData)
        }

        let result = await manager.loginWithEmail(identifier: "test@example.com", password: "wrong_password")

        #expect(result == .failure("Invalid email/username or password"))
        #expect(manager.user == nil)
        #expect(manager.token == nil)
        #expect(manager.error == "Invalid email/username or password")
        #expect(tokenStore.get(account: "current_user_token") == nil)
    }

    @Test
    @MainActor
    func verifyEmailOTPSuccessfulStoresCredentialsAndToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let tokenStore = InMemoryTokenStore()
        let manager = AuthManager(userDefaults: mockDefaults, urlSession: mockSession, tokenStore: tokenStore, autoRestoreSession: false)

        let expectedUser = AuthUser(id: 88, username: "verifieduser", email: "verified@example.com")
        let responsePayload = AuthResponse(
            message: "Email verified successfully!",
            token: "verified-jwt-token-999",
            refreshToken: "verified-refresh-token-888",
            user: expectedUser
        )
        let responseData = try JSONEncoder().encode(responsePayload)

        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/api/auth/verify-email")
            #expect(request.httpMethod == "POST")

            if let body = request.httpBody, let req = try? JSONDecoder().decode(VerifyEmailRequest.self, from: body) {
                #expect(req.email == "verified@example.com")
                #expect(req.otp == "123456")
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseData)
        }

        let success = await manager.verifyEmailOTP(email: "verified@example.com", otp: "123456")

        #expect(success)
        #expect(manager.user == expectedUser)
        #expect(manager.token == "verified-jwt-token-999")
        #expect(manager.refreshToken == "verified-refresh-token-888")
        #expect(tokenStore.get(account: "current_user_token") == "verified-jwt-token-999")
    }

    @Test
    @MainActor
    func verifyEmailOTPFailureSetsErrorState() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let tokenStore = InMemoryTokenStore()
        let manager = AuthManager(userDefaults: mockDefaults, urlSession: mockSession, tokenStore: tokenStore, autoRestoreSession: false)

        let errorPayload = AuthErrorResponse(error: "Invalid verification code")
        let responseData = try JSONEncoder().encode(errorPayload)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseData)
        }

        let success = await manager.verifyEmailOTP(email: "user@example.com", otp: "000000")

        #expect(!success)
        #expect(manager.token == nil)
        #expect(manager.error == "Invalid verification code")
    }

    @Test
    @MainActor
    func resendOTPSuccessful() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let manager = AuthManager(userDefaults: mockDefaults, urlSession: mockSession, tokenStore: InMemoryTokenStore(), autoRestoreSession: false)

        let responsePayload = GenericMessageResponse(message: "Verification code resent successfully. Please check your email.")
        let responseData = try JSONEncoder().encode(responsePayload)

        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/api/auth/resend-otp")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseData)
        }

        let (success, message) = await manager.resendOTP(email: "user@example.com")

        #expect(success)
        #expect(message == "Verification code resent successfully. Please check your email.")
    }

    @Test
    @MainActor
    func logoutClearsAllPersistentDataAndState() async throws {
        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let tokenStore = InMemoryTokenStore()
        let manager = AuthManager(userDefaults: mockDefaults, tokenStore: tokenStore, autoRestoreSession: false)
        let dummyUser = AuthUser(id: 1, username: "test", email: "test@example.com")
        manager.user = dummyUser
        manager.token = "some-token"
        manager.refreshToken = "some-refresh-token"

        tokenStore.save(token: "some-token", account: "current_user_token")
        tokenStore.save(token: "some-refresh-token", account: "current_user_refresh_token")
        let userData = try! JSONEncoder().encode(dummyUser)
        mockDefaults.set(userData, forKey: "currentUserInfo")

        manager.logout()

        #expect(manager.user == nil)
        #expect(manager.token == nil)
        #expect(manager.refreshToken == nil)
        #expect(tokenStore.get(account: "current_user_token") == nil)
        #expect(tokenStore.get(account: "current_user_refresh_token") == nil)
        #expect(mockDefaults.data(forKey: "currentUserInfo") == nil)
    }

    @Test
    @MainActor
    func loginWithAppleSuccessfulStoresCredentialsAndToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let tokenStore = InMemoryTokenStore()
        let manager = AuthManager(userDefaults: mockDefaults, urlSession: mockSession, tokenStore: tokenStore, autoRestoreSession: false)

        let expectedUser = AuthUser(id: 99, username: "apple_user", email: "jane.doe@example.com")
        let responsePayload = AuthResponse(
            message: "Apple login successful",
            token: "apple-jwt-token-xyz",
            user: expectedUser
        )
        let responseData = try JSONEncoder().encode(responsePayload)

        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/api/auth/apple")
            #expect(request.httpMethod == "POST")

            if let bodyData = request.httpBody {
                let decodedRequest = try? JSONDecoder().decode(AppleAuthRequest.self, from: bodyData)
                #expect(decodedRequest?.identityToken == "mock-identity-token")
                #expect(decodedRequest?.userIdentifier == "mock-user-id")
                #expect(decodedRequest?.firstName == "Jane")
                #expect(decodedRequest?.lastName == "Doe")
                #expect(decodedRequest?.email == "jane.doe@example.com")
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseData)
        }

        let success = await manager.loginWithApple(
            identityToken: "mock-identity-token",
            authorizationCode: "mock-auth-code",
            userIdentifier: "mock-user-id",
            firstName: "Jane",
            lastName: "Doe",
            email: "jane.doe@example.com"
        )

        #expect(success)
        #expect(manager.user == expectedUser)
        #expect(manager.token == "apple-jwt-token-xyz")
        #expect(manager.error == nil)

        // Verify storage
        #expect(tokenStore.get(account: "current_user_token") == "apple-jwt-token-xyz")
        if let storedData = mockDefaults.data(forKey: "currentUserInfo"),
           let storedUser = try? JSONDecoder().decode(AuthUser.self, from: storedData) {
            #expect(storedUser == expectedUser)
        } else {
            Issue.record("User not saved in UserDefaults")
        }
    }

    @Test
    @MainActor
    func refreshAccessTokenNetworkErrorReturnsNetworkError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let tokenStore = InMemoryTokenStore()
        let manager = AuthManager(userDefaults: mockDefaults, urlSession: mockSession, tokenStore: tokenStore, autoRestoreSession: false)

        // Set up stored refresh token
        tokenStore.save(token: "valid-refresh-token", account: "current_user_refresh_token")

        // Simulate network failure during refresh request
        MockURLProtocol.requestHandler = { _ in
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."])
        }

        let result = await manager.refreshAccessTokenDetailed()

        #expect(result == .networkError)
    }

    @Test
    @MainActor
    func refreshAccessTokenInvalidTokenReturnsInvalidToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let tokenStore = InMemoryTokenStore()
        let manager = AuthManager(userDefaults: mockDefaults, urlSession: mockSession, tokenStore: tokenStore, autoRestoreSession: false)

        // Set up stored refresh token
        tokenStore.save(token: "expired-refresh-token", account: "current_user_refresh_token")

        let errorPayload = AuthErrorResponse(error: "Invalid refresh token")
        let responseData = try JSONEncoder().encode(errorPayload)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseData)
        }

        let result = await manager.refreshAccessTokenDetailed()

        #expect(result == .invalidToken)
    }
}
