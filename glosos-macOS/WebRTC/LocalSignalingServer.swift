//
//  LocalSignalingServer.swift
//  glosos-macOS
//
//  Created by Antigravity on 7/26/26.
//

import Combine
import Foundation
import Network

@MainActor
public protocol LocalSignalingServerDelegate: AnyObject {
    func localSignalingServer(_ server: LocalSignalingServer, didReceiveOffer sdp: String) async throws -> String
    func localSignalingServer(_ server: LocalSignalingServer, didReceiveCandidate candidate: String, sdpMid: String?, sdpMLineIndex: Int32) async
}

@MainActor
public final class LocalSignalingServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var listeningPort: UInt16 = 8080
    @Published private(set) var statusMessage = "Stopped"

    public weak var delegate: LocalSignalingServerDelegate?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.glosos.local-signaling-server", qos: .userInitiated)

    public init(port: UInt16 = 8080) {
        self.listeningPort = port
    }

    public func start(port: UInt16? = nil) {
        if let requestedPort = port {
            self.listeningPort = requestedPort
        }

        guard !isRunning else {
            print("[LocalSignalingServer] Already running on port \(listeningPort)")
            return
        }

        do {
            guard let nwPort = NWEndpoint.Port(rawValue: listeningPort) else {
                statusMessage = "Invalid port \(listeningPort)"
                return
            }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let newListener = try NWListener(using: parameters, on: nwPort)
            self.listener = newListener

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        if let actualPort = newListener.port?.rawValue {
                            self.listeningPort = actualPort
                        }
                        self.isRunning = true
                        self.statusMessage = "Listening on http://127.0.0.1:\(self.listeningPort)"
                        print("[LocalSignalingServer] Listening on http://127.0.0.1:\(self.listeningPort)")
                    case .failed(let error):
                        self.isRunning = false
                        self.statusMessage = "Server failed: \(error.localizedDescription)"
                        print("[LocalSignalingServer] Failed: \(error.localizedDescription)")
                        self.stop()
                    case .cancelled:
                        self.isRunning = false
                        self.statusMessage = "Stopped"
                        print("[LocalSignalingServer] Server stopped.")
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }

            newListener.start(queue: queue)
        } catch {
            isRunning = false
            statusMessage = "Failed to start: \(error.localizedDescription)"
            print("[LocalSignalingServer] Start error: \(error.localizedDescription)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        statusMessage = "Stopped"
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveFullHTTPRequest(connection: connection, accumulatedData: Data())
    }

    private func receiveFullHTTPRequest(connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            var buffer = accumulatedData
            if let data = content, !data.isEmpty {
                buffer.append(data)
            }

            if isComplete || error != nil {
                if buffer.isEmpty {
                    connection.cancel()
                    return
                }
            }

            // Check if complete headers (\r\n\r\n) have arrived
            if let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headersData = buffer[..<headerEndRange.lowerBound]
                let bodyData = buffer[headerEndRange.upperBound...]

                if let headersString = String(data: headersData, encoding: .utf8) {
                    var expectedContentLength = 0
                    for line in headersString.components(separatedBy: "\r\n") {
                        let lowerLine = line.lowercased()
                        if lowerLine.hasPrefix("content-length:") {
                            let valueString = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                            expectedContentLength = Int(valueString) ?? 0
                        }
                    }

                    // Wait for the full body if more data is expected
                    if bodyData.count < expectedContentLength && !isComplete && error == nil {
                        self.receiveFullHTTPRequest(connection: connection, accumulatedData: buffer)
                        return
                    }
                }

                Task { @MainActor in
                    await self.processHTTPRequest(data: buffer, connection: connection)
                }
            } else if !isComplete && error == nil {
                self.receiveFullHTTPRequest(connection: connection, accumulatedData: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func processHTTPRequest(data: Data, connection: NWConnection) async {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendHTTPResponse(connection: connection, statusCode: 400, statusText: "Bad Request", body: "Invalid UTF-8")
            return
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first, !firstLine.isEmpty else {
            sendHTTPResponse(connection: connection, statusCode: 400, statusText: "Bad Request", body: "Empty request line")
            return
        }

        let components = firstLine.components(separatedBy: " ")
        guard components.count >= 2 else {
            sendHTTPResponse(connection: connection, statusCode: 400, statusText: "Bad Request", body: "Malformed HTTP line")
            return
        }

        let method = components[0].uppercased()
        let path = components[1]

        var bodyData = Data()
        if let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)) {
            bodyData = data.subdata(in: headerEndRange.upperBound..<data.count)
        }

        if method == "OPTIONS" {
            sendCORSResponse(connection: connection)
            return
        }

        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            sendHTTPResponse(
                connection: connection,
                statusCode: 200,
                statusText: "OK",
                contentType: "text/html; charset=utf-8",
                body: self.embeddedWebUIHTML()
            )

        case ("GET", "/api/status"):
            let statusJSON = "{\"status\":\"running\",\"port\":\(listeningPort),\"message\":\"\(statusMessage)\"}"
            sendHTTPResponse(connection: connection, statusCode: 200, statusText: "OK", contentType: "application/json", body: statusJSON)

        case ("POST", "/api/webrtc/offer"):
            do {
                struct OfferPayload: Codable {
                    let sdp: String
                }
                let payload = try JSONDecoder().decode(OfferPayload.self, from: bodyData)
                guard let delegate = self.delegate else {
                    sendHTTPResponse(connection: connection, statusCode: 503, statusText: "Service Unavailable", body: "{\"error\":\"No server delegate configured\"}")
                    return
                }

                let answerSdp = try await delegate.localSignalingServer(self, didReceiveOffer: payload.sdp)
                struct AnswerResponse: Codable {
                    let type: String
                    let sdp: String
                }
                let responsePayload = AnswerResponse(type: "answer", sdp: answerSdp)
                let responseData = try JSONEncoder().encode(responsePayload)
                sendHTTPResponse(
                    connection: connection,
                    statusCode: 200,
                    statusText: "OK",
                    contentType: "application/json",
                    bodyData: responseData
                )
            } catch {
                sendHTTPResponse(connection: connection, statusCode: 400, statusText: "Bad Request", body: "{\"error\":\"\(error.localizedDescription)\"}")
            }

        case ("POST", "/api/webrtc/candidate"):
            struct CandidatePayload: Codable {
                let candidate: String
                let sdpMid: String?
                let sdpMLineIndex: Int32?
            }
            if let payload = try? JSONDecoder().decode(CandidatePayload.self, from: bodyData) {
                await self.delegate?.localSignalingServer(
                    self,
                    didReceiveCandidate: payload.candidate,
                    sdpMid: payload.sdpMid,
                    sdpMLineIndex: payload.sdpMLineIndex ?? 0
                )
                sendHTTPResponse(connection: connection, statusCode: 200, statusText: "OK", contentType: "application/json", body: "{\"status\":\"candidate_received\"}")
            } else {
                sendHTTPResponse(connection: connection, statusCode: 400, statusText: "Bad Request", body: "{\"error\":\"Invalid candidate payload\"}")
            }

        default:
            sendHTTPResponse(connection: connection, statusCode: 404, statusText: "Not Found", body: "Endpoint not found")
        }
    }

    private func sendCORSResponse(connection: NWConnection) {
        let headers = [
            "HTTP/1.1 204 No Content",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
            "Connection: close",
            "\r\n"
        ].joined(separator: "\r\n")

        connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendHTTPResponse(
        connection: NWConnection,
        statusCode: Int,
        statusText: String,
        contentType: String = "text/plain",
        body: String
    ) {
        sendHTTPResponse(
            connection: connection,
            statusCode: statusCode,
            statusText: statusText,
            contentType: contentType,
            bodyData: Data(body.utf8)
        )
    }

    private func sendHTTPResponse(
        connection: NWConnection,
        statusCode: Int,
        statusText: String,
        contentType: String,
        bodyData: Data
    ) {
        let header = [
            "HTTP/1.1 \(statusCode) \(statusText)",
            "Content-Type: \(contentType)",
            "Content-Length: \(bodyData.count)",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Headers: Content-Type",
            "Connection: close",
            "\r\n"
        ].joined(separator: "\r\n")

        var fullData = Data(header.utf8)
        fullData.append(bodyData)

        connection.send(content: fullData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func embeddedWebUIHTML() -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Glosos Local Direct Client</title>
            <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Outfit:wght@500;600;700;800&display=swap">
            <style>
                :root {
                    --font-sans: 'Inter', system-ui, -apple-system, sans-serif;
                    --font-display: 'Outfit', system-ui, -apple-system, sans-serif;
                    --bg-primary: #0b0c10;
                    --bg-secondary: #13141f;
                    --bg-tertiary: #1b1c2e;
                    --primary: #74bf69;
                    --primary-hover: #5fa355;
                    --primary-glow: rgba(116, 191, 105, 0.2);
                    --secondary: #8dd985;
                    --accent: #14b8a6;
                    --accent-glow: rgba(20, 184, 166, 0.2);
                    --text-primary: #f8fafc;
                    --text-secondary: #94a3b8;
                    --text-muted: #64748b;
                    --danger: #ef4444;
                    --danger-hover: #dc2626;
                    --success: #10b981;
                    --success-hover: #059669;
                    --border: rgba(255, 255, 255, 0.08);
                    --glass-bg: rgba(20, 21, 33, 0.7);
                    --glass-border: rgba(255, 255, 255, 0.08);
                    --glass-shadow: 0 12px 40px rgba(0, 0, 0, 0.5);
                    --glass-blur: 16px;
                }

                * { box-sizing: border-box; }

                body {
                    font-family: var(--font-sans);
                    background-color: var(--bg-primary);
                    background-image: 
                        radial-gradient(at 0% 0%, rgba(116, 191, 105, 0.12) 0px, transparent 50%),
                        radial-gradient(at 100% 100%, rgba(20, 184, 166, 0.12) 0px, transparent 50%);
                    background-attachment: fixed;
                    color: var(--text-primary);
                    min-height: 100vh;
                    margin: 0;
                    padding: 24px;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                }

                .glass-panel {
                    background: var(--glass-bg);
                    backdrop-filter: blur(var(--glass-blur));
                    -webkit-backdrop-filter: blur(var(--glass-blur));
                    border: 1px solid var(--glass-border);
                    box-shadow: var(--glass-shadow);
                    border-radius: 20px;
                }

                /* Header */
                .app-header {
                    width: 100%;
                    max-width: 900px;
                    padding: 16px 24px;
                    margin-bottom: 24px;
                    display: flex;
                    align-items: center;
                    justify-content: space-between;
                }
                .brand {
                    display: flex;
                    align-items: center;
                    gap: 12px;
                }
                .brand-icon {
                    width: 38px;
                    height: 38px;
                    background: linear-gradient(135deg, var(--primary), var(--accent));
                    border-radius: 10px;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    box-shadow: 0 4px 14px var(--primary-glow);
                }
                .brand-icon svg { width: 22px; height: 22px; fill: none; stroke: #fff; stroke-width: 2; }
                .brand-title {
                    font-family: var(--font-display);
                    font-size: 1.5rem;
                    font-weight: 700;
                    margin: 0;
                    background: linear-gradient(135deg, #fff 40%, var(--text-secondary));
                    -webkit-background-clip: text;
                    -webkit-text-fill-color: transparent;
                }
                .server-badge {
                    font-size: 0.8rem;
                    font-weight: 600;
                    color: var(--text-secondary);
                    background: rgba(255, 255, 255, 0.05);
                    padding: 6px 14px;
                    border-radius: 20px;
                    border: 1px solid var(--border);
                    display: flex;
                    align-items: center;
                    gap: 8px;
                }
                .pulse-indicator {
                    width: 8px;
                    height: 8px;
                    border-radius: 50%;
                    background: var(--success);
                    box-shadow: 0 0 8px var(--success);
                    animation: pulse-online 2s infinite;
                }
                @keyframes pulse-online {
                    0%, 100% { transform: scale(1); opacity: 1; }
                    50% { transform: scale(1.4); opacity: 0.4; }
                }

                /* Layout Container */
                .layout-grid {
                    width: 100%;
                    max-width: 900px;
                    display: grid;
                    grid-template-columns: 340px 1fr;
                    gap: 24px;
                }
                @media (max-width: 820px) {
                    .layout-grid { grid-template-columns: 1fr; }
                }

                /* Left Control Panel */
                .control-card {
                    padding: 28px;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    text-align: center;
                }
                .card-title {
                    font-family: var(--font-display);
                    font-size: 1.25rem;
                    margin: 0 0 6px 0;
                }
                .card-subtitle {
                    color: var(--text-secondary);
                    font-size: 0.85rem;
                    margin-bottom: 24px;
                    line-height: 1.4;
                }
                .status-badge {
                    display: inline-flex;
                    align-items: center;
                    gap: 8px;
                    padding: 6px 16px;
                    border-radius: 20px;
                    font-size: 0.85rem;
                    font-weight: 600;
                    background: rgba(255, 255, 255, 0.05);
                    color: var(--text-secondary);
                    border: 1px solid var(--border);
                    margin-bottom: 24px;
                    transition: all 0.3s ease;
                }
                .status-badge.connected {
                    background: rgba(16, 185, 129, 0.15);
                    color: #34d399;
                    border-color: rgba(16, 185, 129, 0.3);
                }
                .status-badge.connecting {
                    background: rgba(245, 158, 11, 0.15);
                    color: #fbbf24;
                    border-color: rgba(245, 158, 11, 0.3);
                }
                .status-badge.failed {
                    background: rgba(239, 68, 68, 0.15);
                    color: #f87171;
                    border-color: rgba(239, 68, 68, 0.3);
                }

                /* Radar Animation */
                .connecting-radar {
                    position: relative;
                    width: 90px;
                    height: 90px;
                    margin-bottom: 24px;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                }
                .radar-circle {
                    position: absolute;
                    border-radius: 50%;
                    border: 1px solid var(--primary);
                    opacity: 0;
                }
                .connecting-radar.active .radar-circle {
                    animation: radar-pulse 2s cubic-bezier(0.215, 0.61, 0.355, 1) infinite;
                }
                .radar-circle.c1 { width: 50px; height: 50px; animation-delay: 0s; }
                .radar-circle.c2 { width: 75px; height: 75px; animation-delay: 0.5s; }
                .radar-circle.c3 { width: 100px; height: 100px; animation-delay: 1s; }
                @keyframes radar-pulse {
                    0% { transform: scale(0.4); opacity: 0.8; }
                    100% { transform: scale(1.2); opacity: 0; }
                }
                .radar-center-icon {
                    width: 44px;
                    height: 44px;
                    background: var(--bg-tertiary);
                    border: 1px solid var(--border);
                    border-radius: 50%;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-size: 20px;
                    z-index: 2;
                }

                /* Buttons */
                button {
                    cursor: pointer;
                    font-family: var(--font-sans);
                    font-weight: 600;
                    transition: all 0.2s ease;
                    border-radius: 10px;
                    border: none;
                    padding: 12px 20px;
                    display: inline-flex;
                    align-items: center;
                    justify-content: center;
                    gap: 8px;
                    white-space: nowrap;
                    font-size: 0.95rem;
                }
                .btn-primary {
                    background: linear-gradient(135deg, var(--primary), var(--secondary));
                    color: #fff;
                    box-shadow: 0 4px 14px var(--primary-glow);
                    width: 100%;
                }
                .btn-primary:hover {
                    transform: translateY(-1px);
                    box-shadow: 0 6px 20px var(--primary-glow);
                    background: linear-gradient(135deg, #8dd985, #5fa355);
                }
                .btn-danger {
                    background: var(--danger);
                    color: #fff;
                    box-shadow: 0 4px 14px rgba(239, 68, 68, 0.3);
                    width: 100%;
                }
                .btn-danger:hover {
                    transform: translateY(-1px);
                    background: var(--danger-hover);
                }
                .btn-secondary {
                    background: rgba(255, 255, 255, 0.06);
                    border: 1px solid var(--border);
                    color: var(--text-primary);
                }
                .btn-secondary:hover {
                    background: rgba(255, 255, 255, 0.12);
                }
                .btn-audio-control {
                    background: rgba(255, 255, 255, 0.08);
                    border: 1px solid var(--border);
                    color: var(--text-primary);
                    padding: 8px 14px;
                    font-size: 0.85rem;
                }
                .btn-audio-control.active {
                    background: rgba(16, 185, 129, 0.15);
                    border-color: rgba(16, 185, 129, 0.4);
                    color: #34d399;
                }
                .btn-audio-control.muted {
                    background: rgba(239, 68, 68, 0.15);
                    border-color: rgba(239, 68, 68, 0.4);
                    color: #f87171;
                }

                /* Soundwave Animation */
                .soundwave-container {
                    display: flex;
                    align-items: flex-end;
                    gap: 3px;
                    height: 16px;
                    margin-top: 14px;
                }
                .soundwave-bar {
                    width: 3px;
                    background: var(--primary);
                    border-radius: 3px;
                    animation: soundwave 1.2s ease-in-out infinite alternate;
                }
                .bar-1 { height: 6px; animation-delay: 0s; }
                .bar-2 { height: 14px; animation-delay: 0.2s; }
                .bar-3 { height: 10px; animation-delay: 0.4s; }
                .bar-4 { height: 16px; animation-delay: 0.1s; }
                @keyframes soundwave {
                    0% { height: 4px; }
                    100% { height: 16px; }
                }

                /* Right Chat Panel */
                .chat-card {
                    display: flex;
                    flex-direction: column;
                    height: 520px;
                    overflow: hidden;
                }
                .chat-header {
                    padding: 16px 20px;
                    border-bottom: 1px solid var(--border);
                    display: flex;
                    align-items: center;
                    justify-content: space-between;
                }
                .peer-info {
                    display: flex;
                    align-items: center;
                    gap: 10px;
                }
                .peer-avatar {
                    width: 34px;
                    height: 34px;
                    border-radius: 50%;
                    background: linear-gradient(135deg, var(--accent), var(--primary));
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-size: 16px;
                }
                .peer-title {
                    font-weight: 600;
                    font-size: 0.95rem;
                }
                .peer-subtitle {
                    font-size: 0.75rem;
                    color: var(--text-secondary);
                }

                .messages-container {
                    flex: 1;
                    padding: 20px;
                    overflow-y: auto;
                    display: flex;
                    flex-direction: column;
                    gap: 12px;
                }
                .empty-messages {
                    margin: auto;
                    text-align: center;
                    color: var(--text-muted);
                    font-size: 0.9rem;
                    max-width: 260px;
                    line-height: 1.5;
                }
                .message-bubble {
                    max-width: 75%;
                    padding: 10px 14px;
                    border-radius: 14px;
                    font-size: 0.9rem;
                    line-height: 1.4;
                    word-wrap: break-word;
                }
                .message-bubble.me {
                    align-self: flex-end;
                    background: linear-gradient(135deg, var(--primary), var(--secondary));
                    color: #fff;
                    border-bottom-right-radius: 2px;
                }
                .message-bubble.them {
                    align-self: flex-start;
                    background: rgba(255, 255, 255, 0.08);
                    border: 1px solid var(--border);
                    color: var(--text-primary);
                    border-bottom-left-radius: 2px;
                }
                .message-time {
                    font-size: 0.7rem;
                    opacity: 0.7;
                    margin-top: 4px;
                    text-align: right;
                }

                .chat-input-bar {
                    padding: 14px 20px;
                    border-top: 1px solid var(--border);
                }
                .chat-form {
                    display: flex;
                    gap: 10px;
                }
                .chat-input {
                    flex: 1;
                    background: rgba(255, 255, 255, 0.04);
                    border: 1px solid var(--border);
                    border-radius: 10px;
                    padding: 10px 16px;
                    color: var(--text-primary);
                    font-family: var(--font-sans);
                    font-size: 0.9rem;
                    outline: none;
                    transition: border-color 0.2s;
                }
                .chat-input:focus {
                    border-color: var(--primary);
                }

                /* Diagnostics Panel */
                .diagnostics-card {
                    width: 100%;
                    max-width: 900px;
                    margin-top: 20px;
                    padding: 16px 24px;
                    font-size: 0.8rem;
                }
                .diag-header {
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    cursor: pointer;
                    user-select: none;
                }
                .diag-title {
                    font-weight: 600;
                    color: var(--text-secondary);
                }
                .diag-grid {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
                    gap: 12px;
                    margin-top: 14px;
                    padding-top: 12px;
                    border-top: 1px solid var(--border);
                }
                .diag-item {
                    display: flex;
                    flex-direction: column;
                    gap: 4px;
                }
                .diag-label { color: var(--text-muted); font-size: 0.75rem; }
                .diag-value { color: var(--text-primary); font-weight: 600; font-family: monospace; }
            </style>
        </head>
        <body>
            <!-- Header -->
            <header class="app-header glass-panel">
                <div class="brand">
                    <div class="brand-icon">
                        <svg viewBox="0 0 24 24"><path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"/><path d="M19 10v1a7 7 0 0 1-14 0v-1"/><line x1="12" x2="12" y1="19" y2="22"/></svg>
                    </div>
                    <div>
                        <h1 class="brand-title">Glosos Local</h1>
                    </div>
                </div>
                <div class="server-badge">
                    <div class="pulse-indicator"></div>
                    <span id="serverStatusText">Port \(listeningPort)</span>
                </div>
            </header>

            <!-- Main Content Layout -->
            <main class="layout-grid">
                <!-- Left Section: Controls -->
                <section class="control-card glass-panel">
                    <h2 class="card-title">Direct P2P Connection</h2>
                    <p class="card-subtitle">Connect audio stream & real-time WebRTC data channel directly to macOS app.</p>

                    <div id="radar" class="connecting-radar">
                        <div class="radar-circle c1"></div>
                        <div class="radar-circle c2"></div>
                        <div class="radar-circle c3"></div>
                        <div class="radar-center-icon">🖥️</div>
                    </div>

                    <div id="statusBadge" class="status-badge">Disconnected</div>

                    <button id="connectBtn" class="btn-primary" onclick="toggleConnection()">Connect Voice & Chat</button>

                    <div id="audioControls" style="display: none; width: 100%; margin-top: 16px; flex-direction: column; align-items: center;">
                        <button id="micBtn" class="btn-audio-control active" onclick="toggleMute()">
                            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"/><path d="M19 10v1a7 7 0 0 1-14 0v-1"/><line x1="12" x2="12" y1="19" y2="22"/></svg>
                            <span>Mic On</span>
                        </button>
                        <div class="soundwave-container" title="Audio channel active">
                            <span class="soundwave-bar bar-1"></span>
                            <span class="soundwave-bar bar-2"></span>
                            <span class="soundwave-bar bar-3"></span>
                            <span class="soundwave-bar bar-4"></span>
                        </div>
                    </div>

                    <audio id="remoteAudio" autoplay style="display: none;"></audio>
                </section>

                <!-- Right Section: Chat -->
                <section class="chat-card glass-panel">
                    <div class="chat-header">
                        <div class="peer-info">
                            <div class="peer-avatar">🖥️</div>
                            <div>
                                <div class="peer-title">macOS Application</div>
                                <div class="peer-subtitle" id="dataChannelStatusText">Data Channel Idle</div>
                            </div>
                        </div>
                        <button id="newSessionBtn" class="btn-secondary" style="padding: 6px 12px; font-size: 0.8rem;" onclick="clearSession()" disabled>
                            New Session
                        </button>
                    </div>

                    <div id="messagesContainer" class="messages-container">
                        <div class="empty-messages" id="emptyPlaceholder">
                            Connect to start encrypted P2P audio and message session with your Mac.
                        </div>
                    </div>

                    <div class="chat-input-bar">
                        <form class="chat-form" id="chatForm" onsubmit="handleSendMessage(event)">
                            <input id="chatInput" class="chat-input" type="text" placeholder="Type message over WebRTC..." disabled />
                            <button id="sendBtn" class="btn-secondary" type="submit" disabled>Send</button>
                        </form>
                    </div>
                </section>
            </main>

            <!-- Diagnostics Panel -->
            <section class="diagnostics-card glass-panel">
                <div class="diag-header" onclick="toggleDiagnostics()">
                    <span class="diag-title">⚙️ WebRTC Diagnostics & ICE Metrics</span>
                    <span id="diagToggleIcon" style="color: var(--text-muted);">▼</span>
                </div>
                <div id="diagBody" class="diag-grid" style="display: none;">
                    <div class="diag-item">
                        <span class="diag-label">ICE Connection State</span>
                        <span class="diag-value" id="diagIceState">new</span>
                    </div>
                    <div class="diag-item">
                        <span class="diag-label">Signaling State</span>
                        <span class="diag-value" id="diagSignalingState">stable</span>
                    </div>
                    <div class="diag-item">
                        <span class="diag-label">ICE Candidates</span>
                        <span class="diag-value" id="diagCandidatesCount">0</span>
                    </div>
                    <div class="diag-item">
                        <span class="diag-label">Data Channel State</span>
                        <span class="diag-value" id="diagDataChannelState">closed</span>
                    </div>
                </div>
            </section>

            <script>
                let pc = null;
                let dataChannel = null;
                let isConnected = false;
                let isMuted = false;
                let candidatesCount = 0;

                function updateUIState(state) {
                    const badge = document.getElementById('statusBadge');
                    const btn = document.getElementById('connectBtn');
                    const radar = document.getElementById('radar');
                    const audioControls = document.getElementById('audioControls');
                    const dcStatus = document.getElementById('dataChannelStatusText');

                    if (state === 'connected') {
                        badge.className = 'status-badge connected';
                        badge.innerText = 'Connected Direct';
                        btn.className = 'btn-danger';
                        btn.innerText = 'Disconnect';
                        radar.className = 'connecting-radar';
                        audioControls.style.display = 'flex';
                        dcStatus.innerText = 'Data Channel Active';
                    } else if (state === 'connecting') {
                        badge.className = 'status-badge connecting';
                        badge.innerText = 'Connecting P2P...';
                        btn.className = 'btn-danger';
                        btn.innerText = 'Cancel';
                        radar.className = 'connecting-radar active';
                        audioControls.style.display = 'none';
                        dcStatus.innerText = 'Negotiating...';
                    } else if (state === 'failed') {
                        badge.className = 'status-badge failed';
                        badge.innerText = 'Connection Failed';
                        btn.className = 'btn-primary';
                        btn.innerText = 'Retry Connection';
                        radar.className = 'connecting-radar';
                        audioControls.style.display = 'none';
                        dcStatus.innerText = 'Disconnected';
                    } else {
                        badge.className = 'status-badge';
                        badge.innerText = 'Disconnected';
                        btn.className = 'btn-primary';
                        btn.innerText = 'Connect Voice & Chat';
                        radar.className = 'connecting-radar';
                        audioControls.style.display = 'none';
                        dcStatus.innerText = 'Data Channel Idle';
                    }
                    updateDiagnostics();
                }

                async function toggleConnection() {
                    if (isConnected || (pc && pc.connectionState === 'connecting')) {
                        closeConnection();
                        return;
                    }

                    updateUIState('connecting');
                    candidatesCount = 0;

                    try {
                        // Request microphone access FIRST so Safari grants origin permissions before RTCPeerConnection creation
                        let stream = null;
                        try {
                            stream = await navigator.mediaDevices.getUserMedia({ audio: true });
                        } catch (err) {
                            console.warn('Microphone access not granted:', err);
                        }

                        pc = new RTCPeerConnection({ iceServers: [] });

                        if (stream) {
                            stream.getTracks().forEach(track => pc.addTrack(track, stream));
                        } else {
                            pc.addTransceiver('audio', { direction: 'recvonly' });
                        }

                        // Remote audio track
                        pc.ontrack = (event) => {
                            const audioEl = document.getElementById('remoteAudio');
                            if (event.streams && event.streams[0]) {
                                audioEl.srcObject = event.streams[0];
                                audioEl.play().catch(e => console.warn('Audio autoplay prevented:', e));
                            }
                        };

                        // ICE Candidate handling
                        pc.onicecandidate = (event) => {
                            if (event.candidate && event.candidate.candidate) {
                                candidatesCount++;
                                updateDiagnostics();
                                fetch('/api/webrtc/candidate', {
                                    method: 'POST',
                                    headers: { 'Content-Type': 'application/json' },
                                    body: JSON.stringify({
                                        candidate: event.candidate.candidate,
                                        sdpMid: event.candidate.sdpMid,
                                        sdpMLineIndex: event.candidate.sdpMLineIndex
                                    })
                                }).catch(err => console.warn('Candidate send error:', err));
                            }
                        };

                        pc.oniceconnectionstatechange = () => {
                            updateDiagnostics();
                            if (pc.iceConnectionState === 'failed') {
                                updateUIState('failed');
                            }
                        };

                        pc.onconnectionstatechange = () => {
                            updateDiagnostics();
                            if (pc.connectionState === 'connected') {
                                isConnected = true;
                                updateUIState('connected');
                            } else if (pc.connectionState === 'failed') {
                                updateUIState('failed');
                            } else if (pc.connectionState === 'disconnected' || pc.connectionState === 'closed') {
                                closeConnection();
                            }
                        };

                        // Create Data Channel for Chat
                        dataChannel = pc.createDataChannel('chat');
                        setupDataChannel(dataChannel);

                        // Also listen for incoming data channel
                        pc.ondatachannel = (event) => {
                            setupDataChannel(event.channel);
                        };

                        const offer = await pc.createOffer();
                        await pc.setLocalDescription(offer);

                        const res = await fetch('/api/webrtc/offer', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ sdp: offer.sdp })
                        });

                        if (!res.ok) {
                            const errText = await res.text();
                            throw new Error('Offer request failed: ' + res.status + ' ' + errText);
                        }
                        const data = await res.json();
                        await pc.setRemoteDescription(new RTCSessionDescription({ type: 'answer', sdp: data.sdp }));

                    } catch (err) {
                        console.error('Connection error:', err);
                        updateUIState('failed');
                        closeConnection(false);
                    }
                }

                function setupDataChannel(channel) {
                    dataChannel = channel;
                    dataChannel.onopen = () => {
                        document.getElementById('chatInput').disabled = false;
                        document.getElementById('sendBtn').disabled = false;
                        document.getElementById('newSessionBtn').disabled = false;
                        document.getElementById('emptyPlaceholder')?.remove();
                        updateDiagnostics();
                    };

                    dataChannel.onmessage = (event) => {
                        if (event.data === '/clear') {
                            clearMessagesUI();
                        } else {
                            try {
                                const parsed = JSON.parse(event.data);
                                appendMessage('macOS App', parsed.text || event.data);
                            } catch (e) {
                                appendMessage('macOS App', event.data);
                            }
                        }
                    };

                    dataChannel.onclose = () => {
                        document.getElementById('chatInput').disabled = true;
                        document.getElementById('sendBtn').disabled = true;
                        document.getElementById('newSessionBtn').disabled = true;
                        updateDiagnostics();
                    };
                }

                function closeConnection(updateUI = true) {
                    if (dataChannel) {
                        dataChannel.close();
                        dataChannel = null;
                    }
                    if (pc) {
                        pc.close();
                        pc = null;
                    }
                    isConnected = false;
                    if (updateUI) updateUIState('disconnected');
                }

                function handleSendMessage(e) {
                    e.preventDefault();
                    const input = document.getElementById('chatInput');
                    const text = input.value.trim();
                    if (!text || !dataChannel || dataChannel.readyState !== 'open') return;

                    dataChannel.send(text);
                    if (text === '/clear') {
                        clearMessagesUI();
                    } else {
                        appendMessage('me', text);
                    }
                    input.value = '';
                }

                function appendMessage(sender, text) {
                    const container = document.getElementById('messagesContainer');
                    document.getElementById('emptyPlaceholder')?.remove();

                    const bubble = document.createElement('div');
                    bubble.className = `message-bubble ${sender === 'me' ? 'me' : 'them'}`;
                    
                    const timeStr = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
                    bubble.innerHTML = `<div>${escapeHtml(text)}</div><div class="message-time">${timeStr}</div>`;
                    
                    container.appendChild(bubble);
                    container.scrollTop = container.scrollHeight;
                }

                function clearSession() {
                    if (dataChannel && dataChannel.readyState === 'open') {
                        dataChannel.send('/clear');
                    }
                    clearMessagesUI();
                }

                function clearMessagesUI() {
                    const container = document.getElementById('messagesContainer');
                    container.innerHTML = '<div class="empty-messages" id="emptyPlaceholder">Session cleared. Send a message to start anew.</div>';
                }

                function toggleMute() {
                    if (!pc) return;
                    const senders = pc.getSenders();
                    senders.forEach(sender => {
                        if (sender.track && sender.track.kind === 'audio') {
                            sender.track.enabled = isMuted; // Toggle enabled
                        }
                    });
                    isMuted = !isMuted;

                    const btn = document.getElementById('micBtn');
                    if (isMuted) {
                        btn.className = 'btn-audio-control muted';
                        btn.querySelector('span').innerText = 'Muted';
                    } else {
                        btn.className = 'btn-audio-control active';
                        btn.querySelector('span').innerText = 'Mic On';
                    }
                }

                function toggleDiagnostics() {
                    const body = document.getElementById('diagBody');
                    const icon = document.getElementById('diagToggleIcon');
                    if (body.style.display === 'none') {
                        body.style.display = 'grid';
                        icon.innerText = '▲';
                    } else {
                        body.style.display = 'none';
                        icon.innerText = '▼';
                    }
                }

                function updateDiagnostics() {
                    document.getElementById('diagIceState').innerText = pc ? pc.iceConnectionState : 'idle';
                    document.getElementById('diagSignalingState').innerText = pc ? pc.signalingState : 'stable';
                    document.getElementById('diagCandidatesCount').innerText = candidatesCount;
                    document.getElementById('diagDataChannelState').innerText = dataChannel ? dataChannel.readyState : 'closed';
                }

                function escapeHtml(str) {
                    return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#039;");
                }
            </script>
        </body>
        </html>
        """
    }
}
