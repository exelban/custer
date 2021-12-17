//
//  menu.swift
//  custer
//
//  Created by Serhiy Mytrovtsiy on 07/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

class MenuBar {
    public let menu: Menu = Menu()
    
    private var item: NSStatusItem
    
    init() {
        self.item = NSStatusBar.system.statusItem(withLength: NSApplication.shared.mainMenu?.menuBarHeight ?? 22)
        self.item.autosaveName = Bundle.main.bundleIdentifier
        
        self.item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        self.item.button?.action = #selector(self.click)
        self.item.button?.target = self
        self.item.button?.image = NSImage(named: NSImage.Name("error"))
    }
    
    public func setImage(_ image: String) {
        self.item.button?.image = NSImage(named: NSImage.Name(image))
    }
    
    @objc private func click(_ sender: NSStatusBarButton) {
        guard let event: NSEvent = NSApp.currentEvent else {
            return
        }
        
        if (event.type == NSEvent.EventType.rightMouseDown) {
            self.item.menu = self.menu
            self.item.button?.performClick(nil)
            self.item.menu = nil
            return
        }
        
        if uri == "" {
            self.menu.showAddressView()
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
}

class Menu: NSMenu {
    init() {
        super.init(title: "")
        
        let volumeTitle = NSMenuItem(title: "Volume", action: nil, keyEquivalent: "")
        volumeTitle.isEnabled = false
        
        let volumeSlider = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let volumeView: NSView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        
        let slider: NSSlider = NSSlider(frame: NSRect(x: 20, y: 6, width: volumeView.frame.width - 40, height: 16))
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = Double(Player.shared.volume)
        slider.isContinuous = true
        slider.action = #selector(self.volumeChange)
        slider.target = self
        
        volumeView.addSubview(slider)
        volumeSlider.view = volumeView
        
        self.addItem(volumeTitle)
        self.addItem(volumeSlider)
        
        self.addItem(NSMenuItem.separator())
        
        let streamAddress = NSMenuItem(title: "Set stream address", action: #selector(self.showAddressView), keyEquivalent: "")
        streamAddress.target = self
        self.addItem(streamAddress)
        
        let clearCache = NSMenuItem(title: "Clear cache", action: #selector(self.clearCache), keyEquivalent: "r")
        clearCache.target = self
        self.addItem(clearCache)
        
        Player.shared.buffer = { (total, current) in
            clearCache.title = "Clear cache (\(current.printSecondsToHoursMinutesSeconds()))"
        }
        
        self.addItem(NSMenuItem.separator())
        
        let autoplay = NSMenuItem(title: "Autoplay", action: #selector(self.toggleAutoplay), keyEquivalent: "")
        autoplay.state = Store.shared.bool(key: "autoplay", defaultValue: false) ? NSControl.StateValue.on : NSControl.StateValue.off
        autoplay.target = self
        self.addItem(autoplay)
        
        let launchAtLogin = NSMenuItem(title: "Start at login", action: #selector(self.toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLogin.state = LaunchAtLogin.isEnabled ? NSControl.StateValue.on : NSControl.StateValue.off
        launchAtLogin.target = self
        self.addItem(launchAtLogin)
        
        let iconInDock = NSMenuItem(title: "Show icon in dock", action: #selector(self.toggleIcon), keyEquivalent: "")
        iconInDock.state = Store.shared.bool(key: "icon", defaultValue: false) ? NSControl.StateValue.on : NSControl.StateValue.off
        iconInDock.target = self
        self.addItem(iconInDock)
        
        self.addItem(NSMenuItem.separator())
        self.addItem(NSMenuItem(title: "Quit Custer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc public func showAddressView() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert: NSAlert = NSAlert()
        
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        alert.messageText = "Stream URL"
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 294, height: 24))
        input.stringValue = uri
        input.cell!.wraps = false
        input.cell!.isScrollable = true
        
        alert.accessoryView = input
        
        switch alert.runModal() {
        case .OK, .alertFirstButtonReturn:
            uri = input.stringValue
        case .cancel, .alertThirdButtonReturn: break
        default: break
        }
    }
    
    @objc private func volumeChange(_ sender: NSSlider) {
        Player.shared.volume = Float(sender.doubleValue)
    }
    
    @objc private func clearCache(_ sender: NSMenuItem) {
        Player.shared.clearBuffer()
    }
    
    @objc private func toggleAutoplay(_ sender: NSMenuItem) {
        let state = sender.state != NSControl.StateValue.on
        sender.state = sender.state == NSControl.StateValue.on ? NSControl.StateValue.off : NSControl.StateValue.on
        
        Store.shared.set(key: "autoplay", value: state)
    }
    
    @objc private func toggleIcon(_ sender: NSMenuItem) {
        let state = sender.state != NSControl.StateValue.on
        sender.state = sender.state == NSControl.StateValue.on ? NSControl.StateValue.off : NSControl.StateValue.on
        
        Store.shared.set(key: "icon", value: state)
        
        let dockIconStatus = state ? NSApplication.ActivationPolicy.regular : NSApplication.ActivationPolicy.accessory
        NSApp.setActivationPolicy(dockIconStatus)
        if state {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
    
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let state = sender.state != NSControl.StateValue.on
        sender.state = sender.state == NSControl.StateValue.on ? NSControl.StateValue.off : NSControl.StateValue.on
        
        LaunchAtLogin.isEnabled = state
        if !Store.shared.exist(key: "runAtLoginInitialized") {
            Store.shared.set(key: "runAtLoginInitialized", value: true)
        }
    }
}
