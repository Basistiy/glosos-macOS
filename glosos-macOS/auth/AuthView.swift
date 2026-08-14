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
    var onDismiss: (() -> Void)? = nil

    @State private var identifier: String = ""
    @State private var password: String = ""
    @State private var otpCode: String = ""
    @State private var pendingEmail: String = ""
    @State private var isVerifyingOTP: Bool = false

    @State private var localError: String? = nil
    @State private var successMessage: String? = nil
    @State private var resendCooldown: Int = 0
    @State private var cooldownTimer: Timer? = nil

    @State private var showSettings = false
    @State private var customEndpoint = ""

    public init(authManager: AuthManager, onDismiss: (() -> Void)? = nil) {
        self.authManager = authManager
        self.onDismiss = onDismiss
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

            VStack(spacing: 0) {
                // Top bar with optional close button
                HStack {
                    Spacer()
                    if let onDismiss = onDismiss {
                        Button {
                            onDismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Color.black.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 16)
                        .padding(.trailing, 16)
                    }
                }

                Spacer()

                VStack(spacing: 20) {
                    // Brand header
                    VStack(spacing: 6) {
                        Text("Glosos")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.14, green: 0.19, blue: 0.16))

                        Text(isVerifyingOTP ? "Verify your email" : "Log in to connect remotely")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.55))
                    }

                    // Form Card
                    VStack(spacing: 16) {
                        // Error message
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

                        // Success / Info message
                        if let successMsg = successMessage {
                            Text(successMsg)
                                .font(.system(.footnote, design: .rounded))
                                .foregroundStyle(Color(red: 0.16, green: 0.57, blue: 0.43))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .background(Color(red: 0.16, green: 0.57, blue: 0.43).opacity(0.08))
                                .cornerRadius(8)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        if isVerifyingOTP {
                            otpVerificationForm
                        } else {
                            loginForm
                        }
                    }
                    .padding(24)
                    .background(.white.opacity(0.85))
                    .cornerRadius(20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.04), radius: 16, x: 0, y: 8)
                    .frame(width: 360)

                    // Advanced Connection Settings
                    VStack(spacing: 8) {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showSettings.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .rotationEffect(showSettings ? .degrees(90) : .degrees(0))
                                Text("Advanced Connection Settings")
                                    .font(.system(.caption, design: .rounded).weight(.medium))
                            }
                            .foregroundStyle(Color.black.opacity(0.45))
                        }
                        .buttonStyle(.plain)

                        if showSettings {
                            VStack(spacing: 8) {
                                TextField("Signaling Server URL", text: $customEndpoint)
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.7))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
                                    )
                                    .font(.system(.footnote, design: .monospaced))

                                Button("Save Endpoint") {
                                    authManager.saveSignalingAPIEndpoint(customEndpoint)
                                    successMessage = "Endpoint saved"
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 16)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .frame(width: 360)
                }

                Spacer()
            }
        }
        .frame(minWidth: 420, minHeight: 520)
        .onAppear {
            customEndpoint = authManager.signalingAPIEndpoint
            authManager.clearError()
        }
        .onDisappear {
            cooldownTimer?.invalidate()
        }
    }

    // MARK: - Email / Password Login Form

    private var loginForm: some View {
        VStack(spacing: 14) {
            // Email or Username input
            VStack(alignment: .leading, spacing: 6) {
                Text("Email or Username")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.black.opacity(0.7))

                HStack(spacing: 8) {
                    Image(systemName: "envelope")
                        .foregroundStyle(Color.black.opacity(0.35))
                        .font(.system(size: 13))

                    TextField("name@example.com", text: $identifier)
                        .textFieldStyle(.plain)
                        .font(.system(.subheadline, design: .rounded))
                        .onSubmit {
                            handleEmailLogin()
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.white)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                )
            }

            // Password input
            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.black.opacity(0.7))

                HStack(spacing: 8) {
                    Image(systemName: "lock")
                        .foregroundStyle(Color.black.opacity(0.35))
                        .font(.system(size: 13))

                    SecureField("••••••••", text: $password)
                        .textFieldStyle(.plain)
                        .font(.system(.subheadline, design: .rounded))
                        .onSubmit {
                            handleEmailLogin()
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.white)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                )
            }

            // Log In Button
            Button {
                handleEmailLogin()
            } label: {
                HStack(spacing: 8) {
                    if authManager.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Log In")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Color(red: 0.18, green: 0.52, blue: 0.42))
                .cornerRadius(10)
                .shadow(color: Color(red: 0.18, green: 0.52, blue: 0.42).opacity(0.2), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(authManager.isLoading || identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)

            // Divider OR
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 1)
                Text("OR")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.35))
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 1)
            }
            .padding(.vertical, 2)

            // Sign in with Apple button
            Button {
                authManager.startAppleWebAuth()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 15))
                    Text("Sign in with Apple")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Color.black)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(authManager.isLoading)
        }
    }

    // MARK: - OTP Verification Form (for unverified email accounts)

    private var otpVerificationForm: some View {
        VStack(spacing: 14) {
            Text("Enter the 6-digit code sent to \(pendingEmail)")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)

            // 6-digit OTP code input
            TextField("000000", text: $otpCode)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
                )
                .onSubmit {
                    handleOTPVerification()
                }

            // Verify & Log In button
            Button {
                handleOTPVerification()
            } label: {
                HStack(spacing: 8) {
                    if authManager.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Verify & Log In")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Color(red: 0.18, green: 0.52, blue: 0.42))
                .cornerRadius(10)
                .shadow(color: Color(red: 0.18, green: 0.52, blue: 0.42).opacity(0.2), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(authManager.isLoading || otpCode.trimmingCharacters(in: .whitespacesAndNewlines).count < 6)

            // Resend Code and Back buttons
            HStack(spacing: 16) {
                Button {
                    handleResendOTP()
                } label: {
                    if resendCooldown > 0 {
                        Text("Resend code in \(resendCooldown)s")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.4))
                    } else {
                        Text("Resend Code")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color(red: 0.18, green: 0.52, blue: 0.42))
                    }
                }
                .buttonStyle(.plain)
                .disabled(resendCooldown > 0 || authManager.isLoading)

                Spacer()

                Button {
                    withAnimation {
                        isVerifyingOTP = false
                        otpCode = ""
                        localError = nil
                        successMessage = nil
                    }
                } label: {
                    Text("Back to Log In")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Actions

    private func handleEmailLogin() {
        localError = nil
        successMessage = nil
        authManager.clearError()

        let trimmedId = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            localError = "Please enter your email or username"
            return
        }

        guard !password.isEmpty else {
            localError = "Please enter your password"
            return
        }

        Task {
            let result = await authManager.loginWithEmail(identifier: trimmedId, password: password)
            switch result {
            case .success:
                onDismiss?()
            case .requiresVerification(let email):
                withAnimation {
                    self.pendingEmail = email
                    self.isVerifyingOTP = true
                    self.successMessage = "A 6-digit verification code was sent to \(email)."
                    startResendCooldown(60)
                }
            case .failure(let errorMsg):
                self.localError = errorMsg
            }
        }
    }

    private func handleOTPVerification() {
        localError = nil
        successMessage = nil
        authManager.clearError()

        let trimmedOtp = otpCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedOtp.count == 6 else {
            localError = "Please enter a 6-digit verification code"
            return
        }

        Task {
            let success = await authManager.verifyEmailOTP(email: pendingEmail, otp: trimmedOtp)
            if success {
                onDismiss?()
            } else {
                localError = authManager.error ?? "Verification failed"
            }
        }
    }

    private func handleResendOTP() {
        localError = nil
        successMessage = nil

        Task {
            let (success, message) = await authManager.resendOTP(email: pendingEmail)
            if success {
                successMessage = message
                startResendCooldown(60)
            } else {
                localError = message
            }
        }
    }

    private func startResendCooldown(_ seconds: Int) {
        resendCooldown = seconds
        cooldownTimer?.invalidate()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                if self.resendCooldown > 0 {
                    self.resendCooldown -= 1
                } else {
                    self.cooldownTimer?.invalidate()
                }
            }
        }
    }
}
