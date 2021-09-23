//
//  AppDelegate.swift
//  custer
//
//  Created by Serhiy Mytrovtsiy on 07/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import os.log
import Updater

let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "custer")
var uri: String {
    get {
        return Store.shared.string(key: "url", defaultValue: "")
    }
    set {
        Store.shared.set(key: "url", value: newValue)
        Player.shared.setURL(newValue)
    }
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar: MenuBar = MenuBar()
    private let updater = Updater(user: "exelban", repo: "custer")
    private let reachability: Reachability = try! Reachability()
    
    private let autostart: Bool = Store.shared.bool(key: "autoplay", defaultValue: false)
    private var lastState: Bool = false
    private var initialized: Bool = false
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        self.parseArguments()
        
        if uri == "" {
            os_log(.debug, log: log, "Stream url is not defined")
            self.menuBar.menu.showAddressView()
        }
        
        Player.shared.delegate = self
        Player.shared.setURL(uri)
        
        self.defaultValues()
        self.checkForNewVersion()
        self.networkReachability()
    }
}

// MARK: - playerDelegate

extension AppDelegate: playerDelegate {
    func onError(error: String) {
        if reachability.connection == .unavailable {
            return
        }
        
        let alert = NSAlert()
        alert.messageText = "Error to start player"
        alert.informativeText = error
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        
        if let window = NSApplication.shared.windows.first {
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
        
        os_log(.error, log: log, "error: %s", error)
    }
    
    func stateChange(state: player_state) {
        os_log(.debug, log: log, "new state: %s", state.description)
        
        switch state {
        case .playing: self.menuBar.setImage("pause")
        case .ready:
            self.menuBar.setImage("play")
            if self.autostart && !self.initialized {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    Player.shared.play()
                }
                self.initialized = true
            }
        case .paused: self.menuBar.setImage("play")
        case .error, .undefined: self.menuBar.setImage("error")
        default: break
        }
    }
}

// MARK: - helpers

extension AppDelegate {
    private func defaultValues() {
        if !Store.shared.exist(key: "runAtLoginInitialized") {
            Store.shared.set(key: "runAtLoginInitialized", value: true)
            LaunchAtLogin.isEnabled = true
        }
        
        if Store.shared.exist(key: "icon") {
            let dockIconStatus = Store.shared.bool(key: "icon", defaultValue: false) ? NSApplication.ActivationPolicy.regular : NSApplication.ActivationPolicy.accessory
            NSApp.setActivationPolicy(dockIconStatus)
        }
    }
    
    private func checkForNewVersion() {
        self.updater.check() { result, error in
            if error != nil {
                os_log(.error, log: log, "error updater.check(): %s", "\(error!.localizedDescription)")
                return
            }
            
            guard error == nil, let version: version_s = result else {
                os_log(.error, log: log, "download error(): %s", "\(error!.localizedDescription)")
                return
            }
            
            DispatchQueue.main.async(execute: {
                if version.newest {
                    os_log(.debug, log: log, "show update window because new version of app found: %s", "\(version.latest)")
                    
                    let alert = NSAlert()
                    alert.messageText = "New version available"
                    alert.informativeText = "Current version:   \(version.current)\nLatest version:     \(version.latest)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Install")
                    alert.addButton(withTitle: "Cancel")
                    
                    if alert.runModal() == .alertFirstButtonReturn {
                        if let url = URL(string: version.url) {
                            self.updater.download(url, doneHandler: { path in
                                self.updater.install(path: path)
                            })
                        }
                    }
                }
            })
        }
    }
    
    private func parseArguments() {
        let args = CommandLine.arguments
        
        if let mountIndex = args.firstIndex(of: "--mount-path") {
            if args.indices.contains(mountIndex+1) {
                let mountPath = args[mountIndex+1]
                asyncShell("/usr/bin/hdiutil detach \(mountPath)")
                asyncShell("/bin/rm -rf \(mountPath)")
                
                os_log(.debug, log: log, "DMG was unmounted and mountPath deleted")
            }
        }
        
        if let dmgIndex = args.firstIndex(of: "--dmg-path") {
            if args.indices.contains(dmgIndex+1) {
                asyncShell("/bin/rm -rf \(args[dmgIndex+1])")
                
                os_log(.debug, log: log, "DMG was deleted")
            }
        }
    }
    
    private func networkReachability() {
        self.reachability.whenReachable = { reachability in
            if self.lastState {
                Player.shared.clearBuffer()
            } else {
                Player.shared.reset(play: false)
            }
        }
        self.reachability.whenUnreachable = { _ in
            self.lastState = Player.shared.isPlaying()
            Player.shared.pause()
        }
        
        do {
            try self.reachability.startNotifier()
        } catch {
            print("Unable to start notifier")
        }
    }
}
