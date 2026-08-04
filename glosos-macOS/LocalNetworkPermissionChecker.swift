//
//  LocalNetworkPermissionChecker.swift
//  glosos-macOS
//
//  Created by EV on 8/2/26.
//

import Foundation
import Combine
import Network
import AppKit

@MainActor
final class LocalNetworkPermissionChecker: ObservableObject {
    static let shared = LocalNetworkPermissionChecker()

    @Published var isLocalNetworkProhibited: Bool = false
    @Published var isChecking: Bool = false
    @Published var lastProbeMessage: String? = nil

    private var pathMonitor: NWPathMonitor?
    private var tcpConnection: NWConnection?
    private var udpConnection: NWConnection?
    private var browser: NWBrowser?

    init() {
        startMonitoring()
    }

    func startMonitoring() {
        checkLocalNetworkAccess()
        triggerBrowserProbe()
    }

    func checkLocalNetworkAccess() {
        let host = NWEndpoint.Host("192.168.64.1")
        let port = NWEndpoint.Port(rawValue: 8000)!
        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let conn = NWConnection(host: host, port: port, using: params)
        self.tcpConnection = conn

        conn.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                if #available(macOS 15.0, *) {
                    if path.unsatisfiedReason == .localNetworkDenied {
                        self?.isLocalNetworkProhibited = true
                    }
                }
            }
        }

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .waiting(let error):
                    if case .posix(let code) = error {
                        if code == .EACCES || code == .EPERM {
                            self?.isLocalNetworkProhibited = true
                        }
                    }
                case .failed(let error):
                    if case .posix(let code) = error, code == .EACCES || code == .EPERM {
                        self?.isLocalNetworkProhibited = true
                    }
                default:
                    break
                }
            }
        }

        let queue = DispatchQueue(label: "com.glosos.networkmonitor")
        conn.start(queue: queue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            conn.cancel()
            self?.tcpConnection = nil
        }
    }

    /// Triggers macOS to display the system "Allow Local Network Access" prompt
    /// by initiating local TCP & UDP network connections and a Bonjour NWBrowser search.
    func triggerLocalNetworkPrompt() {
        isChecking = true
        lastProbeMessage = "Triggering local network probe..."
        print("[LocalNetworkPermissionChecker] Probing local network to trigger macOS permission prompt...")

        checkLocalNetworkAccess()
        triggerUDPProbe()
        triggerBrowserProbe()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.isChecking = false
            if self?.isLocalNetworkProhibited == true {
                self?.lastProbeMessage = "Local network is blocked by macOS. Please enable Glosos in System Settings."
            } else {
                self?.lastProbeMessage = "Probe complete. Check if macOS requested permission or open System Settings."
            }
        }
    }

    private func triggerUDPProbe() {
        let host = NWEndpoint.Host("224.0.0.251")
        guard let port = NWEndpoint.Port(rawValue: 5353) else { return }

        let params = NWParameters.udp
        params.includePeerToPeer = true
        let udpConn = NWConnection(host: host, port: port, using: params)
        self.udpConnection = udpConn

        udpConn.start(queue: DispatchQueue(label: "com.glosos.udpprobe"))
        let dummyData = "GLOSOS_LOCAL_NETWORK_PROBE".data(using: .utf8)
        udpConn.send(content: dummyData, completion: .contentProcessed({ _ in
            udpConn.cancel()
        }))

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            udpConn.cancel()
            self?.udpConnection = nil
        }
    }

    private func triggerBrowserProbe() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_http._tcp", domain: "local.")
        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let browser = NWBrowser(for: descriptor, using: params)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                print("[LocalNetworkPermissionChecker] Browser probe state: \(state)")
                if case .failed(let error) = state {
                    if case .posix(let code) = error, code == .EACCES || code == .EPERM {
                        self?.isLocalNetworkProhibited = true
                    }
                }
            }
        }

        browser.start(queue: DispatchQueue(label: "com.glosos.browserprobe"))

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            browser.cancel()
            self?.browser = nil
        }
    }

    func openLocalNetworkPrivacySettings() {
        print("[LocalNetworkPermissionChecker] Opening macOS System Settings -> Privacy & Security -> Local Network...")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }
}
