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
    
    private func animateClick() {
        guard let button = self.item.button else {
            return
        }
        
        button.wantsLayer = true
        
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, 0.72, 1.12, 1.0]
        animation.keyTimes = [0.0, 0.15, 0.45, 1.0]
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn)
        ]
        animation.duration = 0.35
        animation.isRemovedOnCompletion = true
        
        button.layer?.add(animation, forKey: "clickBounce")
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
        
        self.animateClick()
        
        if uri == "" {
            self.menu.showAddressView()
            return
        }
        
        if Player.shared.isError() {
            Player.shared.reset(play: true)
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
    private let streamsMenu: NSMenu = NSMenu()
    
    init() {
        super.init(title: "")
        
        let volumeTitle = NSMenuItem(title: "Volume", action: nil, keyEquivalent: "")
        volumeTitle.isEnabled = false
        
        let volumeSlider = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let volumeView: NSView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        volumeView.autoresizingMask = .width

        let slider: NSSlider = NSSlider(frame: NSRect(x: 20, y: 6, width: volumeView.frame.width - 40, height: 16))
        slider.autoresizingMask = .width
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
        
        let streamAddress = NSMenuItem(title: "Set stream address", action: nil, keyEquivalent: "")
        streamAddress.submenu = self.streamsMenu
        self.addItem(streamAddress)
        self.rebuildStreamsMenu()
        
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
        self.showStreamEditor(index: nil)
    }
    
    public func rebuildStreamsMenu() {
        self.streamsMenu.removeAllItems()
        
        let current = uri
        let list = streams
        
        if list.isEmpty {
            let empty = NSMenuItem(title: "No streams", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            self.streamsMenu.addItem(empty)
        } else {
            for (i, s) in list.enumerated() {
                let title = s.name.isEmpty ? s.url : s.name
                let item = NSMenuItem(title: title, action: #selector(self.selectStream(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                item.state = (s.url == current && !current.isEmpty) ? .on : .off
                item.toolTip = s.url
                self.streamsMenu.addItem(item)
            }
        }
        
        self.streamsMenu.addItem(NSMenuItem.separator())
        
        let add = NSMenuItem(title: "Add...", action: #selector(self.addStream), keyEquivalent: "")
        add.target = self
        self.streamsMenu.addItem(add)
        
        if !list.isEmpty {
            let editSubmenu = NSMenu()
            for (i, s) in list.enumerated() {
                let title = s.name.isEmpty ? s.url : s.name
                let it = NSMenuItem(title: title, action: #selector(self.editStream(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
                editSubmenu.addItem(it)
            }
            let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            edit.submenu = editSubmenu
            self.streamsMenu.addItem(edit)
            
            let removeSubmenu = NSMenu()
            for (i, s) in list.enumerated() {
                let title = s.name.isEmpty ? s.url : s.name
                let it = NSMenuItem(title: title, action: #selector(self.removeStream(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
                removeSubmenu.addItem(it)
            }
            let remove = NSMenuItem(title: "Remove", action: nil, keyEquivalent: "")
            remove.submenu = removeSubmenu
            self.streamsMenu.addItem(remove)
        }
    }
    
    @objc private func selectStream(_ sender: NSMenuItem) {
        let list = streams
        guard sender.tag >= 0 && sender.tag < list.count else { return }
        uri = list[sender.tag].url
        self.rebuildStreamsMenu()
    }
    
    @objc private func addStream() {
        self.showStreamEditor(index: nil)
    }
    
    @objc private func editStream(_ sender: NSMenuItem) {
        self.showStreamEditor(index: sender.tag)
    }
    
    @objc private func removeStream(_ sender: NSMenuItem) {
        var list = streams
        guard sender.tag >= 0 && sender.tag < list.count else { return }
        let target = list[sender.tag]
        
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = "Remove stream"
        alert.informativeText = "Are you sure you want to remove \"\(target.name.isEmpty ? target.url : target.name)\"?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        
        let removed = list.remove(at: sender.tag)
        streams = list
        if removed.url == uri {
            uri = list.first?.url ?? ""
        }
        self.rebuildStreamsMenu()
    }
    
    private func showStreamEditor(index: Int?) {
        NSApplication.shared.activate()
        let alert: NSAlert = NSAlert()
        
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        alert.messageText = index == nil ? "Add stream" : "Edit stream"
        
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 294, height: 54))
        
        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 294, height: 24))
        nameField.placeholderString = "Name"
        
        let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 294, height: 24))
        urlField.placeholderString = "URL"
        urlField.cell!.wraps = false
        urlField.cell!.isScrollable = true
        
        var list = streams
        if let i = index, i >= 0 && i < list.count {
            nameField.stringValue = list[i].name
            urlField.stringValue = list[i].url
        }
        
        container.addSubview(nameField)
        container.addSubview(urlField)
        alert.accessoryView = container
        
        switch alert.runModal() {
        case .OK, .alertFirstButtonReturn:
            let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.isEmpty { return }
            let newStream = Stream(name: nameField.stringValue, url: url)
            if let i = index, i >= 0 && i < list.count {
                let old = list[i]
                list[i] = newStream
                streams = list
                if old.url == uri {
                    uri = newStream.url
                }
            } else {
                list.append(newStream)
                streams = list
                if uri.isEmpty {
                    uri = newStream.url
                }
            }
            self.rebuildStreamsMenu()
        case .cancel, .alertSecondButtonReturn: break
        default: break
        }
    }
    
    @objc private func volumeChange(_ sender: NSSlider) {
        // avoid writing to UserDefaults on every tick while the slider is dragged
        let eventType = NSApp.currentEvent?.type
        let isDragging = eventType == .leftMouseDown || eventType == .leftMouseDragged
        Player.shared.setVolume(Float(sender.doubleValue), persist: !isDragging)
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
            NSApplication.shared.activate()
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
