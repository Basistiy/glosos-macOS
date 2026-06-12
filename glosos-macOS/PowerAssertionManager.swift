//
//  PowerAssertionManager.swift
//  glosos-macOS
//
//  Created by Antigravity on 6/12/26.
//

import Foundation
import Combine

class PowerAssertionManager: ObservableObject {
    static let shared = PowerAssertionManager()
    
    private var activityToken: NSObjectProtocol?
    
    @Published private(set) var isSleepPrevented: Bool = false
    
    private init() {}
    
    func preventSleep(reason: String = "Glosos background peer services active") {
        guard activityToken == nil else { return }
        
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .background],
            reason: reason
        )
        isSleepPrevented = activityToken != nil
        if isSleepPrevented {
            print("PowerAssertionManager: Prevented system sleep (reason: \(reason))")
        } else {
            print("PowerAssertionManager: Failed to prevent system sleep")
        }
    }
    
    func allowSleep() {
        guard let token = activityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
        isSleepPrevented = false
        print("PowerAssertionManager: Allowed system sleep")
    }
    
    func updateAssertion(shouldPreventSleep: Bool) {
        if shouldPreventSleep {
            preventSleep()
        } else {
            allowSleep()
        }
    }
}
