//
//  menu.swift
//  mRadio
//
//  Created by Serhiy Mytrovtsiy on 07/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

internal class Menu: NSMenu {
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
        
        let clearCache = NSMenuItem(title: "Clear cache", action: #selector(self.clearCache), keyEquivalent: "")
        clearCache.target = self
        self.addItem(clearCache)
        
        let autoplay = NSMenuItem(title: "Autoplay", action: #selector(self.toggleAutoplay), keyEquivalent: "")
        autoplay.state = store.bool(key: "autoplay", defaultValue: false) ? NSControl.StateValue.on : NSControl.StateValue.off
        autoplay.target = self
        self.addItem(autoplay)
        
        let launchAtLogin = NSMenuItem(title: "Start at login", action: #selector(self.toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLogin.state = LaunchAtLogin.isEnabled ? NSControl.StateValue.on : NSControl.StateValue.off
        launchAtLogin.target = self
        self.addItem(launchAtLogin)
        
        self.addItem(NSMenuItem.separator())
        self.addItem(NSMenuItem(title: "Quit mRadio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc func volumeChange(_ sender: NSSlider) {
        Player.shared.setVolume(Float(sender.doubleValue))
        store.set(key: "volume", value: Float(sender.doubleValue))
    }
    
    @objc func clearCache(_ sender: NSMenuItem) {
        Player.shared.clearBuffer()
    }
    
    @objc func toggleAutoplay(_ sender: NSMenuItem) {
        let state = sender.state != NSControl.StateValue.on
        sender.state = sender.state == NSControl.StateValue.on ? NSControl.StateValue.off : NSControl.StateValue.on
        
        store.set(key: "autoplay", value: state)
    }
    
    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let state = sender.state != NSControl.StateValue.on
        sender.state = sender.state == NSControl.StateValue.on ? NSControl.StateValue.off : NSControl.StateValue.on
        
        LaunchAtLogin.isEnabled = state
        if !store.exist(key: "runAtLoginInitialized") {
            store.set(key: "runAtLoginInitialized", value: true)
        }
    }
}
