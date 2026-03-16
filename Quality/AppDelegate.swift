//
//  AppDelegate.swift
//  Quality
//
//  Created by Vincent Neo on 21/4/22.
//

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    
    static private(set) var instance: AppDelegate! = nil
    var outputDevices: OutputDevices!
    
    func checkPermissions() {
        Task.detached(priority: .utility) {
            do {
                if try !User.current.isAdmin() {
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "Requires Privileges"
                        alert.informativeText = "LosslessSwitcher requires Administrator privileges in order to detect audio sample rate changes from system logs."
                        alert.alertStyle = .critical
                        alert.runModal()
                        NSApp.terminate(self)
                    }
                }
            }
            catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Requires Privileges"
                    alert.informativeText = "LosslessSwitcher could not check if your account has Administrator privileges. If your account lacks Administrator privileges, sample rate detection will not work."
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.instance = self
        checkPermissions()
    }
}
