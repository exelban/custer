//
//  AppDelegate.swift
//  mRadio
//
//  Created by Serhiy Mytrovtsiy on 07/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import os.log

let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "mRadio")
var store: Store = Store()
var uri: String {
    get {
        return store.string(key: "url", defaultValue: "https://n-6-12.dcs.redcdn.pl/sc/o2/Eurozet/live/audio.livx")
    }
    set {
        store.set(key: "url", value: newValue)
        Player.shared.setURL(newValue)
    }
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, playerDelegate {
    
    private let menuBarItem = NSStatusBar.system.statusItem(withLength: 28)
    private let autostart: Bool = store.bool(key: "autoplay", defaultValue: false)
    private let menu: NSMenu = Menu()
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        self.menuBarItem.autosaveName = "mRadio"
        
        self.menuBarItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        self.menuBarItem.button?.action = #selector(click(_:))
        
        Player.shared.delegate = self
        Player.shared.setURL(uri)
        
        if !store.exist(key: "runAtLoginInitialized") {
            store.set(key: "runAtLoginInitialized", value: true)
            LaunchAtLogin.isEnabled = true
        }
        
        if store.exist(key: "icon") {
            let dockIconStatus = store.bool(key: "icon", defaultValue: false) ? NSApplication.ActivationPolicy.regular : NSApplication.ActivationPolicy.accessory
            NSApp.setActivationPolicy(dockIconStatus)
        }
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {}
    
    @objc func click(_ sender: NSStatusBarButton) {
        guard let event: NSEvent = NSApp.currentEvent else {
            return
        }
        
        if (event.type == NSEvent.EventType.rightMouseDown) {
            self.menuBarItem.menu = self.menu
            self.menuBarItem.button?.performClick(nil)
            self.menuBarItem.menu = nil
            return
        }
        
        if Player.shared.isError() {
            return
        }
        
        if Player.shared.isPlaying() {
            Player.shared.pause()
            return
        }
        
        Player.shared.play()
    }
    
    func onError(error: String) {
        let alert = NSAlert()
        alert.messageText = "Error to start player"
        alert.informativeText = error
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        
        if let window = NSApplication.shared.windows.first{
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
        
        os_log(.error, log: log, "error: %s", error)
    }
    
    func stateChange(state: player_state) {
        os_log(.debug, log: log, "new state: %s", state.description)
        
        switch state {
        case .playing:
            self.menuBarItem.button?.image = NSImage(named: NSImage.Name("pause"))
        case .ready:
        self.menuBarItem.button?.image = NSImage(named: NSImage.Name("play"))
            if self.autostart {
                Player.shared.play()
            }
        case .paused:
            self.menuBarItem.button?.image = NSImage(named: NSImage.Name("play"))
        case .error:
            self.menuBarItem.button?.image = NSImage(named: NSImage.Name("error"))
        default:
            break
        }
    }
}

