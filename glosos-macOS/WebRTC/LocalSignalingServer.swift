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
        receiveNextHTTPMessage(connection)
    }

    private func receiveNextHTTPMessage(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if let data = content, !data.isEmpty {
                Task { @MainActor in
                    await self.processHTTPRequest(data: data, connection: connection)
                }
            } else if isComplete || error != nil {
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
        if let doubleNewlineRange = requestString.range(of: "\r\n\r\n") {
            let bodyString = String(requestString[doubleNewlineRange.upperBound...])
            bodyData = Data(bodyString.utf8)
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
            <title>Glosos Local Web Client</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    background: #121214;
                    color: #e0e0e0;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                    justify-content: center;
                    min-height: 100vh;
                    margin: 0;
                    padding: 20px;
                }
                .card {
                    background: #1e1e24;
                    border: 1px solid #2e2e38;
                    border-radius: 16px;
                    padding: 32px;
                    max-width: 480px;
                    width: 100%;
                    box-shadow: 0 8px 32px rgba(0,0,0,0.4);
                    text-align: center;
                }
                h1 { margin-top: 0; color: #fff; font-size: 24px; }
                p { color: #a0a0b0; font-size: 14px; line-height: 1.5; }
                .status-badge {
                    display: inline-block;
                    padding: 6px 16px;
                    border-radius: 20px;
                    font-size: 13px;
                    font-weight: 600;
                    background: #2a2a36;
                    color: #aaa;
                    margin-bottom: 24px;
                }
                .status-badge.connected { background: #1b4d2e; color: #4caf50; }
                button {
                    background: #4f46e5;
                    color: white;
                    border: none;
                    padding: 14px 28px;
                    border-radius: 10px;
                    font-size: 16px;
                    font-weight: 600;
                    cursor: pointer;
                    width: 100%;
                    transition: background 0.2s;
                }
                button:hover { background: #4338ca; }
                button:disabled { background: #373740; color: #777; cursor: not-allowed; }
                audio { width: 100%; margin-top: 20px; }
            </style>
        </head>
        <body>
            <div class="card">
                <h1>Glosos Local Mode</h1>
                <p>Embedded local WebRTC server running directly on your Mac.</p>
                <div id="status" class="status-badge">Disconnected</div>
                <button id="connectBtn" onclick="toggleConnection()">Connect Voice</button>
                <audio id="remoteAudio" autoplay></audio>
            </div>

            <script>
                let pc = null;
                let isConnected = false;

                async function toggleConnection() {
                    const btn = document.getElementById('connectBtn');
                    const status = document.getElementById('status');

                    if (isConnected) {
                        if (pc) pc.close();
                        pc = null;
                        isConnected = false;
                        status.className = 'status-badge';
                        status.innerText = 'Disconnected';
                        btn.innerText = 'Connect Voice';
                        return;
                    }

                    btn.disabled = true;
                    status.innerText = 'Connecting...';

                    try {
                        pc = new RTCPeerConnection({ iceServers: [] });
                        const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
                        stream.getTracks().forEach(track => pc.addTrack(track, stream));

                        pc.ontrack = (event) => {
                            const audioEl = document.getElementById('remoteAudio');
                            if (event.streams && event.streams[0]) {
                                audioEl.srcObject = event.streams[0];
                            }
                        };

                        pc.onicecandidate = (event) => {
                            if (event.candidate) {
                                fetch('/api/webrtc/candidate', {
                                    method: 'POST',
                                    headers: { 'Content-Type': 'application/json' },
                                    body: JSON.stringify({
                                        candidate: event.candidate.candidate,
                                        sdpMid: event.candidate.sdpMid,
                                        sdpMLineIndex: event.candidate.sdpMLineIndex
                                    })
                                });
                            }
                        };

                        const offer = await pc.createOffer();
                        await pc.setLocalDescription(offer);

                        const res = await fetch('/api/webrtc/offer', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ sdp: offer.sdp })
                        });

                        const data = await res.json();
                        await pc.setRemoteDescription(new RTCSessionDescription({ type: 'answer', sdp: data.sdp }));

                        isConnected = true;
                        status.className = 'status-badge connected';
                        status.innerText = 'Connected Direct';
                        btn.innerText = 'Disconnect';
                    } catch (err) {
                        console.error(err);
                        status.innerText = 'Connection Error';
                    } finally {
                        btn.disabled = false;
                    }
                }
            </script>
        </body>
        </html>
        """
    }
}
