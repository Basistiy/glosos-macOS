//
//  NWConnectionHTTPClient.swift
//  glosos-macOS
//
//  Created by Antigravity on 8/4/26.
//

import Foundation
import Network

enum NWHTTPError: Error, LocalizedError {
    case invalidURL
    case connectionFailed(String)
    case httpFailure(statusCode: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .httpFailure(let code, let msg): return "HTTP Error \(code): \(msg)"
        case .invalidResponse: return "Invalid HTTP response format"
        }
    }
}

nonisolated final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private var isDone = false
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>, connection: NWConnection) {
        lock.lock()
        defer { lock.unlock() }
        guard !isDone else { return }
        isDone = true
        connection.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}

nonisolated final class DataBox: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    init() {}

    func append(_ newContent: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(newContent)
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

nonisolated final class StreamBufferBox: @unchecked Sendable {
    private var buffer = Data()
    private var headersParsed = false
    private let lock = NSLock()

    init() {}

    func appendAndExtractLines(_ content: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(content)
        if !headersParsed {
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                headersParsed = true
                buffer.removeSubrange(..<headerEnd.upperBound)
            } else {
                return []
            }
        }

        var lines: [String] = []
        while let lineEnd = buffer.range(of: Data("\n".utf8)) {
            let lineData = buffer[..<lineEnd.lowerBound]
            buffer.removeSubrange(..<lineEnd.upperBound)
            if let lineStr = String(data: lineData, encoding: .utf8) {
                lines.append(lineStr)
            }
        }
        return lines
    }
}

/// A lightweight HTTP client using Network.framework's raw `NWConnection` (TCP sockets).
/// Bypasses CFNetwork/URLSession path evaluation errors on virtual bridge interfaces (`bridge100`).
nonisolated final class NWConnectionHTTPClient: Sendable {
    static let shared = NWConnectionHTTPClient()

    /// Performs a non-streaming HTTP request (GET, POST) over raw TCP socket.
    func request(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutSeconds: Double = 10
    ) async throws -> (statusCode: Int, bodyData: Data) {
        guard let host = url.host else {
            throw NWHTTPError.invalidURL
        }
        let portInt = url.port ?? (url.scheme == "https" ? 443 : 80)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(portInt)) else {
            throw NWHTTPError.invalidURL
        }

        let nwHost = NWEndpoint.Host(host)
        let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)

        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            let queue = DispatchQueue(label: "com.glosos.nwhttp.\(UUID().uuidString)")

            connection.pathUpdateHandler = { path in
                if #available(macOS 15.0, *) {
                    if path.unsatisfiedReason == .localNetworkDenied {
                        print("[NWConnectionHTTPClient] macOS Local Network permission denied for target: \(host):\(portInt)")
                        box.resume(
                            with: .failure(NWHTTPError.connectionFailed("Local network permission denied by macOS (localNetworkDenied)")),
                            connection: connection
                        )
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let path = url.path.isEmpty ? "/" : url.path + (url.query != nil ? "?\(url.query!)" : "")
                    var rawRequest = "\(method) \(path) HTTP/1.1\r\nHost: \(host):\(portInt)\r\nConnection: close\r\n"
                    for (k, v) in headers {
                        rawRequest += "\(k): \(v)\r\n"
                    }
                    if let body {
                        rawRequest += "Content-Length: \(body.count)\r\n"
                    }
                    rawRequest += "\r\n"

                    var reqData = Data(rawRequest.utf8)
                    if let body {
                        reqData.append(body)
                    }

                    connection.send(content: reqData, completion: .contentProcessed { error in
                        if let error {
                            print("[NWConnectionHTTPClient] Send error to \(host):\(portInt): \(error.localizedDescription)")
                            box.resume(with: .failure(NWHTTPError.connectionFailed(error.localizedDescription)), connection: connection)
                            return
                        }

                        let buffer = DataBox()
                        Self.readAllData(connection: connection, buffer: buffer, box: box)
                    })

                case .waiting(let error):
                    print("[NWConnectionHTTPClient] Connection to \(host):\(portInt) is waiting: \(error.localizedDescription)")
                    if case .posix(let code) = error {
                        if code == .EACCES || code == .EPERM {
                            print("[NWConnectionHTTPClient] Permission Denied (POSIX \(code.rawValue)) for target \(host):\(portInt)")
                            box.resume(
                                with: .failure(NWHTTPError.connectionFailed("Local network permission denied (POSIX \(code.rawValue): \(error.localizedDescription))")),
                                connection: connection
                            )
                        }
                    }

                case .failed(let error):
                    print("[NWConnectionHTTPClient] Connection to \(host):\(portInt) failed: \(error.localizedDescription)")
                    box.resume(with: .failure(NWHTTPError.connectionFailed(error.localizedDescription)), connection: connection)
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                let stateDesc = String(describing: connection.state)
                print("[NWConnectionHTTPClient] Request to \(url) timed out after \(Int(timeoutSeconds))s (connection state: \(stateDesc))")
                box.resume(with: .failure(NWHTTPError.connectionFailed("Request timed out after \(Int(timeoutSeconds))s (state: \(stateDesc))")), connection: connection)
            }

            connection.start(queue: queue)
        }
    }

    private static func readAllData(
        connection: NWConnection,
        buffer: DataBox,
        box: ContinuationBox<(statusCode: Int, bodyData: Data)>
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, err in
            if let content {
                buffer.append(content)
            }
            if isComplete || err != nil {
                let responseData = buffer.data
                guard let headerEnd = responseData.range(of: Data("\r\n\r\n".utf8)) else {
                    box.resume(with: .failure(NWHTTPError.invalidResponse), connection: connection)
                    return
                }

                let headersData = responseData[..<headerEnd.lowerBound]
                let bodyData = responseData[headerEnd.upperBound...]

                guard let headerText = String(data: headersData, encoding: .utf8),
                      let firstLine = headerText.components(separatedBy: "\r\n").first else {
                    box.resume(with: .failure(NWHTTPError.invalidResponse), connection: connection)
                    return
                }

                let parts = firstLine.components(separatedBy: " ")
                guard parts.count >= 2, let statusCode = Int(parts[1]) else {
                    box.resume(with: .failure(NWHTTPError.invalidResponse), connection: connection)
                    return
                }

                box.resume(with: .success((statusCode: statusCode, bodyData: Data(bodyData))), connection: connection)
            } else {
                readAllData(connection: connection, buffer: buffer, box: box)
            }
        }
    }

    /// Performs a line-streaming HTTP request (SSE / streaming responses) over raw TCP socket.
    func streamRequest(
        url: URL,
        method: String = "POST",
        headers: [String: String] = [:],
        body: Data?,
        onLine: @escaping @Sendable (String) async -> Void
    ) async throws {
        guard let host = url.host else {
            throw NWHTTPError.invalidURL
        }
        let portInt = url.port ?? (url.scheme == "https" ? 443 : 80)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(portInt)) else {
            throw NWHTTPError.invalidURL
        }

        let nwHost = NWEndpoint.Host(host)
        let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(continuation)
            let queue = DispatchQueue(label: "com.glosos.nwhttpstream.\(UUID().uuidString)")

            connection.pathUpdateHandler = { path in
                if #available(macOS 15.0, *) {
                    if path.unsatisfiedReason == .localNetworkDenied {
                        print("[NWConnectionHTTPClient] Stream: macOS Local Network permission denied for target: \(host):\(portInt)")
                        box.resume(
                            with: .failure(NWHTTPError.connectionFailed("Local network permission denied by macOS (localNetworkDenied)")),
                            connection: connection
                        )
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let path = url.path.isEmpty ? "/" : url.path + (url.query != nil ? "?\(url.query!)" : "")
                    var rawRequest = "\(method) \(path) HTTP/1.1\r\nHost: \(host):\(portInt)\r\nConnection: close\r\n"
                    for (k, v) in headers {
                        rawRequest += "\(k): \(v)\r\n"
                    }
                    if let body {
                        rawRequest += "Content-Length: \(body.count)\r\n"
                    }
                    rawRequest += "\r\n"

                    var reqData = Data(rawRequest.utf8)
                    if let body {
                        reqData.append(body)
                    }

                    connection.send(content: reqData, completion: .contentProcessed { error in
                        if let error {
                            print("[NWConnectionHTTPClient] Stream send error to \(host):\(portInt): \(error.localizedDescription)")
                            box.resume(with: .failure(NWHTTPError.connectionFailed(error.localizedDescription)), connection: connection)
                            return
                        }

                        let streamBuffer = StreamBufferBox()
                        Self.readStreamData(connection: connection, streamBuffer: streamBuffer, box: box, onLine: onLine)
                    })

                case .waiting(let error):
                    print("[NWConnectionHTTPClient] Stream connection to \(host):\(portInt) is waiting: \(error.localizedDescription)")
                    if case .posix(let code) = error {
                        if code == .EACCES || code == .EPERM {
                            print("[NWConnectionHTTPClient] Stream: Permission Denied (POSIX \(code.rawValue)) for target \(host):\(portInt)")
                            box.resume(
                                with: .failure(NWHTTPError.connectionFailed("Local network permission denied (POSIX \(code.rawValue): \(error.localizedDescription))")),
                                connection: connection
                            )
                        }
                    }

                case .failed(let error):
                    print("[NWConnectionHTTPClient] Stream connection to \(host):\(portInt) failed: \(error.localizedDescription)")
                    box.resume(with: .failure(NWHTTPError.connectionFailed(error.localizedDescription)), connection: connection)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    private static func readStreamData(
        connection: NWConnection,
        streamBuffer: StreamBufferBox,
        box: ContinuationBox<Void>,
        onLine: @escaping @Sendable (String) async -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, err in
            Task {
                if let content {
                    let lines = streamBuffer.appendAndExtractLines(content)
                    for line in lines {
                        await onLine(line)
                    }
                }

                if isComplete || err != nil {
                    box.resume(with: .success(()), connection: connection)
                } else {
                    readStreamData(connection: connection, streamBuffer: streamBuffer, box: box, onLine: onLine)
                }
            }
        }
    }
}
