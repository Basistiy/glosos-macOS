//
//  AuthView.swift
//  glosos-macOS
//
//  Created by Antigravity on 6/9/26.
//

import SwiftUI
import AuthenticationServices

public struct AuthView: View {
    @ObservedObject var authManager: AuthManager

    @State private var localError: String? = nil

    @State private var showSettings = false
    @State private var customEndpoint = ""

    public init(authManager: AuthManager) {
        self.authManager = authManager
    }

    public var body: some View {
        ZStack {
            // Elegant background gradient matching the chat theme
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.95, blue: 0.92),
                    Color(red: 0.93, green: 0.94, blue: 0.91)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Header brand logo/title
                VStack(spacing: 8) {
                    Text("Glosos Signaling")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.14, green: 0.19, blue: 0.16))

                    Text("Sign in to start WebRTC P2P")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.5))
                }

                // Form Card
                VStack(spacing: 16) {
                    // Error display (local validation or manager API error)
                    if let errorMessage = localError ?? authManager.error {
                        Text(errorMessage)
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(Color(red: 0.70, green: 0.28, blue: 0.23))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .background(Color(red: 0.70, green: 0.28, blue: 0.23).opacity(0.08))
                            .cornerRadius(8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Button {
                        authManager.startAppleWebAuth()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 16))
                            Text("Sign in with Apple")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Color.black)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(authManager.isLoading)
                }
                .padding(24)
                .background(.white.opacity(0.82))
                .cornerRadius(24)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.03), radius: 15, x: 0, y: 10)
                .frame(maxWidth: 400)

                // Advanced Server Settings Toggle
                VStack(spacing: 12) {
                    Button {
                        withAnimation {
                            showSettings.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .rotationEffect(showSettings ? .degrees(90) : .degrees(0))
                            Text("Advanced Connection Settings")
                                .font(.system(.footnote, design: .rounded).weight(.semibold))
                        }
                        .foregroundStyle(Color.black.opacity(0.4))
                    }
                    .buttonStyle(.plain)

                    if showSettings {
                        VStack(spacing: 8) {
                            TextField("Signaling Server URL", text: $customEndpoint)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.6))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.black.opacity(0.04), lineWidth: 1)
                                )
                                .font(.system(.footnote, design: .monospaced))

                            Button("Save Endpoint") {
                                authManager.saveSignalingAPIEndpoint(customEndpoint)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: 400)

                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            customEndpoint = authManager.signalingAPIEndpoint
            authManager.clearError()
        }
    }

    private func handleAppleSignInCompletion(_ result: Result<ASAuthorization, Error>) {
        localError = nil
        authManager.clearError()

        switch result {
        case .success(let authorization):
            if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
                let userIdentifier = appleIDCredential.user
                let firstName = appleIDCredential.fullName?.givenName
                let lastName = appleIDCredential.fullName?.familyName
                let email = appleIDCredential.email

                guard let identityTokenData = appleIDCredential.identityToken,
                      let identityTokenString = String(data: identityTokenData, encoding: .utf8) else {
                    localError = "Apple Sign In: Missing identity token."
                    return
                }

                let authCodeString: String?
                if let authCodeData = appleIDCredential.authorizationCode {
                    authCodeString = String(data: authCodeData, encoding: .utf8)
                } else {
                    authCodeString = nil
                }

                Task {
                    _ = await authManager.loginWithApple(
                        identityToken: identityTokenString,
                        authorizationCode: authCodeString,
                        userIdentifier: userIdentifier,
                        firstName: firstName,
                        lastName: lastName,
                        email: email
                    )
                }
            } else {
                localError = "Apple Sign In failed: Unsupported credential type."
            }
        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain == ASAuthorizationErrorDomain && nsError.code == ASAuthorizationError.canceled.rawValue {
                return
            }
            localError = "Apple Sign In failed: \(error.localizedDescription)"
        }
    }
}
