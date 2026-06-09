//
//  AuthManagerTests.swift
//  glosos-macOSTests
//
//  Created by Antigravity on 6/9/26.
//

import Foundation
import Testing
@testable import glosos_macOS

/// A mock URLProtocol to intercept URLSession network requests in tests
private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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
    func loginSuccessfulStoresCredentialsAndToken() async throws {
        KeychainHelper.delete(account: "current_user_token")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let manager = AuthManager(userDefaults: mockDefaults, urlSession: mockSession)

        let expectedUser = AuthUser(id: 42, username: "testuser")
        let responsePayload = AuthResponse(
            message: "Login successful",
            token: "valid-jwt-token-xyz",
            user: expectedUser
        )
        let responseData = try JSONEncoder().encode(responsePayload)

        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/api/auth/login")
            #expect(request.httpMethod == "POST")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseData)
        }

        let success = await manager.login(username: "testuser", password: "password123")

        #expect(success)
        #expect(manager.user == expectedUser)
        #expect(manager.token == "valid-jwt-token-xyz")
        #expect(manager.error == nil)

        // Verify storage
        #expect(KeychainHelper.get(account: "current_user_token") == "valid-jwt-token-xyz")
        if let storedData = mockDefaults.data(forKey: "currentUserInfo"),
           let storedUser = try? JSONDecoder().decode(AuthUser.self, from: storedData) {
            #expect(storedUser == expectedUser)
        } else {
            Issue.record("User not saved in UserDefaults")
        }

        // Clean up
        KeychainHelper.delete(account: "current_user_token")
    }

    @Test
    @MainActor
    func loginFailureSetsErrorState() async throws {
        KeychainHelper.delete(account: "current_user_token")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let manager = AuthManager(userDefaults: mockDefaults, urlSession: mockSession)

        let errorPayload = AuthErrorResponse(error: "Invalid username or password")
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

        let success = await manager.login(username: "testuser", password: "wrong_password")

        #expect(!success)
        #expect(manager.user == nil)
        #expect(manager.token == nil)
        #expect(manager.error == "Invalid username or password")
        #expect(KeychainHelper.get(account: "current_user_token") == nil)
    }

    @Test
    @MainActor
    func registerSuccessfulStoresCredentials() async throws {
        KeychainHelper.delete(account: "current_user_token")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let manager = AuthManager(userDefaults: mockDefaults, urlSession: mockSession)

        let expectedUser = AuthUser(id: 100, username: "newuser")
        let responsePayload = AuthResponse(
            message: "User registered successfully",
            token: "new-jwt-token-123",
            user: expectedUser
        )
        let responseData = try JSONEncoder().encode(responsePayload)

        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/api/auth/register")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseData)
        }

        let success = await manager.register(username: "newuser", password: "password123")

        #expect(success)
        #expect(manager.user == expectedUser)
        #expect(manager.token == "new-jwt-token-123")
        #expect(KeychainHelper.get(account: "current_user_token") == "new-jwt-token-123")

        // Clean up
        KeychainHelper.delete(account: "current_user_token")
    }

    @Test
    @MainActor
    func logoutClearsAllPersistentDataAndState() async throws {
        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let manager = AuthManager(userDefaults: mockDefaults)
        let dummyUser = AuthUser(id: 1, username: "test")
        manager.user = dummyUser
        manager.token = "some-token"

        KeychainHelper.save(token: "some-token", account: "current_user_token")
        let userData = try! JSONEncoder().encode(dummyUser)
        mockDefaults.set(userData, forKey: "currentUserInfo")

        manager.logout()

        #expect(manager.user == nil)
        #expect(manager.token == nil)
        #expect(KeychainHelper.get(account: "current_user_token") == nil)
        #expect(mockDefaults.data(forKey: "currentUserInfo") == nil)
    }

    @Test
    @MainActor
    func enteringOfflineModeSetsBypassStateAndResetsOnLogout() async throws {
        let suiteName = "AuthManagerTests.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.removePersistentDomain(forName: suiteName)

        let manager = AuthManager(userDefaults: mockDefaults)
        manager.user = AuthUser(id: 1, username: "test")
        manager.token = "some-token"

        manager.enterOfflineMode()

        #expect(manager.user == nil)
        #expect(manager.token == nil)
        #expect(manager.isOfflineMode == true)

        manager.logout()
        #expect(manager.isOfflineMode == false)
    }
}
