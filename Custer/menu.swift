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

/// Stream bookkeeping the menu delegates to the app, so the menu stays a view.
@MainActor
protocol MenuActions: AnyObject {
    func select(stream: Stream)
    func save(stream: Stream, at index: Int?)
    func remove(streamAt index: Int)
}

// MARK: - MenuBar

@MainActor
class MenuBar {
    public let menu: Menu = Menu()
    
    private var item: NSStatusItem
    private var scrollMonitor: Any? = nil
    private var scrollPersistTimer: Timer? = nil
    private var state: PlayerState = .undefined
    
    init() {
        self.item = NSStatusBar.system.statusItem(withLength: NSApplication.shared.mainMenu?.menuBarHeight ?? 22)
        self.item.autosaveName = Bundle.main.bundleIdentifier
        
        self.item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        self.item.button?.action = #selector(self.click)
        self.item.button?.target = self
        self.item.button?.image = NSImage(named: NSImage.Name("error"))
        self.item.button?.setAccessibilityLabel("Custer")
        self.refreshTooltip()
        
        // scroll over the icon changes the volume
        self.scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, let button = self.item.button, event.window == button.window else {
                return event
            }
            self.scroll(event)
            return nil
        }
    }
    
    public func setState(_ state: PlayerState) {
        self.state = state
        
        let name: String
        switch state {
        case .playing, .loading: name = "pause"
        case .ready, .paused, .stopped: name = "play"
        case .error, .undefined: name = "error"
        }
        self.item.button?.image = NSImage(named: NSImage.Name(name))
        // a dimmed pause icon means "connecting": audio has been requested but is not flowing yet
        self.item.button?.appearsDisabled = state == .loading
        self.refreshTooltip()
    }
    
    public func refreshTooltip() {
        var lines: [String] = []
        if let stream = Player.shared.stream {
            lines.append(stream.displayName)
            if let title = Player.shared.currentTitle {
                lines.append(title)
            }
            lines.append(self.menu.statusText())
        } else {
            lines.append("No stream selected")
        }
        lines.append("")
        lines.append(Settings.shared.clickOpensMenu
            ? "Click: menu · Scroll: volume"
            : "Left click: play/pause · Right click: menu · Scroll: volume")
        self.item.button?.toolTip = lines.joined(separator: "\n")
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
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true
        if !Settings.shared.clickOpensMenu && !isContextClick {
            self.animateClick()
            if Player.shared.stream == nil {
                self.menu.showAddressView()
            } else {
                Player.shared.toggle()
            }
            return
        }
        self.item.menu = self.menu
        self.item.button?.performClick(nil)
        self.item.menu = nil
    }
    
    private func scroll(_ event: NSEvent) {
        guard Player.shared.stream != nil else { return }
        
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            delta *= 4
        }
        guard delta != 0 else { return }
        
        // base on the slider, not the stored value: the stored value only updates once the wheel stops
        let volume = min(max(self.menu.currentVolume() + Float(delta) * 0.01, 0), 1)
        Player.shared.setVolume(volume, persist: false)
        if Player.shared.isMuted && delta > 0 {
            Player.shared.isMuted = false
        }
        self.menu.refreshVolume(volume)
        
        // persist once the wheel stops instead of on every tick
        self.scrollPersistTimer?.invalidate()
        self.scrollPersistTimer = Timer.scheduledTimer(timeInterval: 0.4, target: self, selector: #selector(self.persistVolume), userInfo: nil, repeats: false)
    }
    
    @objc private func persistVolume() {
        self.scrollPersistTimer = nil
        self.menu.persistVolume()
    }
}

// MARK: - Menu

@MainActor
class Menu: NSMenu, NSMenuDelegate {
    public weak var actions: MenuActions? = nil
    
    private let playItem = NSMenuItem(title: "Play", action: #selector(togglePlayback), keyEquivalent: " ")
    private let streamItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let trackItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let copyTitleItem = NSMenuItem(title: "Copy song title", action: #selector(copyTitle), keyEquivalent: "c")
    private let reconnectItem = NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "r")
    private let muteItem = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "m")
    private let slider: NSSlider = NSSlider(frame: NSRect(x: 0, y: 0, width: 100, height: 16))
    private let volumeView: NSView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
    private var refreshTimer: Timer? = nil
    
    init() {
        super.init(title: "")
        self.delegate = self
        self.autoenablesItems = false
        
        self.playItem.target = self
        self.playItem.keyEquivalentModifierMask = []
        self.streamItem.isEnabled = false
        self.trackItem.isEnabled = false
        self.copyTitleItem.target = self
        self.reconnectItem.target = self
        self.muteItem.target = self
        
        self.buildVolumeView()
        self.rebuild()
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - building
    
    private func buildVolumeView() {
        self.volumeView.autoresizingMask = .width
        
        let low = NSImageView(frame: NSRect(x: 14, y: 6, width: 16, height: 16))
        low.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: "Low volume")
        low.contentTintColor = .secondaryLabelColor
        low.autoresizingMask = .maxXMargin
        
        let high = NSImageView(frame: NSRect(x: self.volumeView.frame.width - 30, y: 6, width: 16, height: 16))
        high.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "High volume")
        high.contentTintColor = .secondaryLabelColor
        high.autoresizingMask = .minXMargin
        
        self.slider.frame = NSRect(x: 34, y: 6, width: self.volumeView.frame.width - 68, height: 16)
        self.slider.autoresizingMask = .width
        self.slider.minValue = 0
        self.slider.maxValue = 1
        self.slider.doubleValue = Double(Player.shared.volume)
        self.slider.isContinuous = true
        self.slider.action = #selector(self.volumeChange)
        self.slider.target = self
        self.slider.setAccessibilityLabel("Volume")
        
        self.volumeView.addSubview(low)
        self.volumeView.addSubview(self.slider)
        self.volumeView.addSubview(high)
    }
    
    /// Rebuilds the whole menu; cheap enough to do whenever the stream list changes.
    public func rebuild() {
        self.removeAllItems()
        
        self.addItem(self.playItem)
        self.addItem(NSMenuItem.separator())
        
        // now playing
        self.addItem(self.streamItem)
        self.addItem(self.trackItem)
        self.addItem(self.copyTitleItem)
        self.addItem(NSMenuItem.separator())
        
        // streams
        let list = Settings.shared.streams
        let current = Settings.shared.currentURL
        if list.isEmpty {
            let empty = NSMenuItem(title: "No streams yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            self.addItem(empty)
        }
        for (i, s) in list.enumerated() {
            let item = NSMenuItem(title: s.displayName, action: #selector(self.selectStream(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
            item.target = self
            item.tag = i
            item.state = (s.url == current && !current.isEmpty) ? .on : .off
            item.toolTip = s.url
            self.addItem(item)
        }
        
        let add = NSMenuItem(title: "Add Stream…", action: #selector(self.addStream), keyEquivalent: "n")
        add.target = self
        self.addItem(add)
        
        if !list.isEmpty {
            let editSubmenu = NSMenu()
            for (i, s) in list.enumerated() {
                let it = NSMenuItem(title: s.displayName, action: #selector(self.editStream(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
                it.toolTip = s.url
                editSubmenu.addItem(it)
            }
            let edit = NSMenuItem(title: "Edit Stream", action: nil, keyEquivalent: "")
            edit.submenu = editSubmenu
            self.addItem(edit)
        }
        
        self.addItem(NSMenuItem.separator())
        
        // volume
        let volumeTitle = NSMenuItem(title: "Volume", action: nil, keyEquivalent: "")
        volumeTitle.isEnabled = false
        self.addItem(volumeTitle)
        
        let volumeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        volumeItem.view = self.volumeView
        self.addItem(volumeItem)
        
        self.muteItem.state = Player.shared.isMuted ? .on : .off
        self.addItem(self.muteItem)
        self.addItem(self.reconnectItem)
        
        self.addItem(NSMenuItem.separator())
        
        // settings
        let clickMenu = NSMenu()
        for (title, opensMenu) in [("Open Menu", true), ("Play / Pause", false)] {
            let option = NSMenuItem(title: title, action: #selector(self.setClickAction), keyEquivalent: "")
            option.target = self
            option.tag = opensMenu ? 1 : 0
            option.state = Settings.shared.clickOpensMenu == opensMenu ? .on : .off
            clickMenu.addItem(option)
        }
        let clickAction = NSMenuItem(title: "Left-click action", action: nil, keyEquivalent: "")
        clickAction.submenu = clickMenu
        self.addItem(clickAction)
        
        let autoplay = NSMenuItem(title: "Autoplay on launch", action: #selector(self.toggleAutoplay), keyEquivalent: "")
        autoplay.state = Settings.shared.autoplay ? .on : .off
        autoplay.target = self
        self.addItem(autoplay)
        
        let launchAtLogin = NSMenuItem(
            title: LaunchAtLogin.requiresApproval ? "Start at login — Approve in System Settings…" : "Start at login",
            action: #selector(self.toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.state = LaunchAtLogin.isEnabled ? .on : .off
        launchAtLogin.target = self
        self.addItem(launchAtLogin)
        
        self.addItem(NSMenuItem.separator())

        let aboutMenu = NSMenu()
        let help = NSMenuItem(title: "Help / Contact…", action: #selector(self.showHelp), keyEquivalent: "")
        help.target = self
        aboutMenu.addItem(help)

        let privacy = NSMenuItem(title: "Privacy Policy…", action: #selector(self.showPrivacy), keyEquivalent: "")
        privacy.target = self
        aboutMenu.addItem(privacy)

        let about = NSMenuItem(title: "About Custer…", action: nil, keyEquivalent: "")
        about.submenu = aboutMenu
        self.addItem(about)

        self.addItem(NSMenuItem.separator())
        self.addItem(NSMenuItem(title: "Quit Custer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        self.refreshStatus()
    }
    
    // MARK: - status
    
    /// Human readable playback state for the status line and tooltip.
    public func statusText() -> String {
        let player = Player.shared
        switch player.state {
        case .playing:
            return "Playing"
        case .loading:
            return player.wantsToPlay ? "Connecting…" : "Loading…"
        case .ready, .paused:
            return "Paused"
        case .stopped, .undefined:
            return player.stream == nil ? "No stream selected" : "Stopped"
        case .error:
            if player.isReconnecting {
                return "Connection lost, reconnecting…"
            }
            return "Error: \(player.lastError ?? "unknown")"
        }
    }
    
    public func refreshStatus() {
        let player = Player.shared
        self.playItem.title = player.wantsToPlay ? "Pause" : "Play"
        self.playItem.isEnabled = player.stream != nil
        
        // long titles must not widen the whole menu: cap the header lines at the slider row width
        let font = NSFont.menuFont(ofSize: 0)
        let maxWidth = self.volumeView.frame.width
        
        if let stream = player.stream {
            self.streamItem.title = stream.displayName.truncated(toWidth: maxWidth, font: font)
            self.streamItem.toolTip = stream.url
        } else {
            self.streamItem.title = "No stream selected"
            self.streamItem.toolTip = nil
        }
        
        let status = self.statusText()
        let visibleTitle: String? = (player.state == .playing || player.state == .loading) ? player.currentTitle : nil
        if let title = visibleTitle {
            self.trackItem.title = title.truncated(toWidth: maxWidth, font: font)
            self.trackItem.toolTip = title
        } else {
            self.trackItem.title = status.truncated(toWidth: maxWidth, font: font)
            self.trackItem.toolTip = status
        }
        
        // the copy item only makes sense while a title is actually shown in the header
        self.copyTitleItem.isEnabled = visibleTitle != nil
        self.copyTitleItem.isHidden = visibleTitle == nil
        
        self.reconnectItem.isEnabled = player.stream != nil
        if let lag = player.secondsBehindLive(), lag >= 1 {
            // fixed-width digits and a clock format keep the title the same width while the menu is open,
            // otherwise NSMenu re-lays itself out and visibly grows on every tick
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
            self.reconnectItem.attributedTitle = NSAttributedString(
                string: "Reconnect (\(lag.clockString()) behind live)",
                attributes: [.font: font]
            )
        } else {
            self.reconnectItem.attributedTitle = nil
            self.reconnectItem.title = "Reconnect"
        }
        
        self.muteItem.state = player.isMuted ? .on : .off
    }
    
    public func currentVolume() -> Float {
        return Float(self.slider.doubleValue)
    }
    
    public func refreshVolume(_ value: Float) {
        self.slider.doubleValue = Double(min(max(value, 0), 1))
    }
    
    public func persistVolume() {
        Player.shared.setVolume(Float(self.slider.doubleValue), persist: true)
    }
    
    // the live-lag readout only needs updating while the menu is visible
    func menuWillOpen(_ menu: NSMenu) {
        self.rebuild()
        self.slider.doubleValue = Double(Player.shared.volume)
        self.refreshTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(self.refreshTick), userInfo: nil, repeats: true)
        RunLoop.main.add(self.refreshTimer!, forMode: .eventTracking)
    }
    
    func menuDidClose(_ menu: NSMenu) {
        self.refreshTimer?.invalidate()
        self.refreshTimer = nil
    }
    
    @objc private func refreshTick() {
        self.refreshStatus()
    }
    
    // MARK: - stream actions
    
    @objc public func showAddressView() {
        self.showStreamEditor(index: nil)
    }
    
    @objc private func selectStream(_ sender: NSMenuItem) {
        let list = Settings.shared.streams
        guard sender.tag >= 0 && sender.tag < list.count else { return }
        self.actions?.select(stream: list[sender.tag])
        self.rebuild()
    }
    
    @objc private func addStream() {
        self.showStreamEditor(index: nil)
    }
    
    @objc private func editStream(_ sender: NSMenuItem) {
        self.showStreamEditor(index: sender.tag)
    }
    
    private func confirmRemove(_ stream: Stream) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove stream"
        alert.informativeText = "Are you sure you want to remove \"\(stream.displayName)\"?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    
    private func showStreamEditor(index: Int?) {
        NSApplication.shared.activate()
        
        let list = Settings.shared.streams
        let editing: Stream? = index.flatMap { $0 >= 0 && $0 < list.count ? list[$0] : nil }
        var name = editing?.name ?? ""
        var url = editing?.url ?? ""
        var errorText: String? = nil
        
        // loop so an invalid URL re-opens the editor with what the user typed instead of dropping it
        while true {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = editing == nil ? "Add stream" : "Edit stream"
            let menuGesture = Settings.shared.clickOpensMenu ? "Click" : "Right-click or Control-click"
            alert.informativeText = errorText ?? "Paste a direct audio stream or M3U/PLS playlist address (HTTP or HTTPS), not a station webpage. \(menuGesture) Custer’s menu bar icon for controls and Quit."
            alert.addButton(withTitle: editing == nil ? "Add" : "Save")
            alert.addButton(withTitle: "Cancel")
            if editing != nil {
                alert.addButton(withTitle: "Remove…")
            }
            
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 294, height: 54))
            
            let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 294, height: 24))
            nameField.placeholderString = "Name"
            nameField.stringValue = name
            nameField.setAccessibilityLabel("Stream name")
            
            let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 294, height: 24))
            urlField.placeholderString = "https://example.com/stream"
            urlField.stringValue = url
            urlField.cell!.wraps = false
            urlField.cell!.isScrollable = true
            urlField.setAccessibilityLabel("Stream URL")
            
            nameField.nextKeyView = urlField
            urlField.nextKeyView = nameField
            
            container.addSubview(nameField)
            container.addSubview(urlField)
            alert.accessoryView = container
            alert.window.initialFirstResponder = errorText == nil ? nameField : urlField
            
            let response = alert.runModal()
            name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            
            switch response {
            case .alertFirstButtonReturn:
                guard let valid = Stream.validate(url: url) else {
                    errorText = url.isEmpty ? "The address is empty." : "\"\(url)\" is not a valid http(s) address."
                    continue
                }
                self.actions?.save(stream: Stream(name: name, url: valid), at: index)
                self.rebuild()
                return
            case .alertThirdButtonReturn:
                if let i = index, let stream = editing, self.confirmRemove(stream) {
                    self.actions?.remove(streamAt: i)
                    self.rebuild()
                    return
                }
                continue
            default:
                return
            }
        }
    }
    
    // MARK: - playback actions
    
    @objc private func copyTitle(_ sender: NSMenuItem) {
        let player = Player.shared
        guard player.state == .playing || player.state == .loading, let title = player.currentTitle else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(title, forType: .string)
    }
    
    @objc private func reconnect(_ sender: NSMenuItem) {
        Player.shared.reconnect()
    }
    
    @objc private func toggleMute(_ sender: NSMenuItem) {
        Player.shared.isMuted.toggle()
        sender.state = Player.shared.isMuted ? .on : .off
    }
    
    @objc private func volumeChange(_ sender: NSSlider) {
        // avoid writing to UserDefaults on every tick while the slider is dragged
        let eventType = NSApp.currentEvent?.type
        let isDragging = eventType == .leftMouseDown || eventType == .leftMouseDragged
        Player.shared.setVolume(Float(sender.doubleValue), persist: !isDragging)
        if Player.shared.isMuted && sender.doubleValue > 0 {
            Player.shared.isMuted = false
            self.muteItem.state = .off
        }
    }
    
    // MARK: - settings actions
    
    @objc private func setClickAction(_ sender: NSMenuItem) {
        Settings.shared.clickOpensMenu = sender.tag == 1
        self.rebuild()
        Player.shared.delegate?.infoChange()
        if !Settings.shared.clickOpensMenu {
            let alert = NSAlert()
            alert.messageText = "Left-click now plays or pauses"
            alert.informativeText = "Right-click or Control-click the menu bar icon to open the menu, change this setting, or quit Custer."
            NSApp.activate()
            alert.runModal()
        }
    }
    
    @objc private func toggleAutoplay(_ sender: NSMenuItem) {
        let state = sender.state != .on
        sender.state = state ? .on : .off
        Settings.shared.autoplay = state
    }
    
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if LaunchAtLogin.requiresApproval {
            LaunchAtLogin.openSettings()
            return
        }

        do {
            try LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
            if LaunchAtLogin.requiresApproval {
                LaunchAtLogin.openSettings()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Start at login"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }

        sender.state = LaunchAtLogin.isEnabled ? .on : .off
    }
    
    @objc private func togglePlayback(_ sender: NSMenuItem) {
        Player.shared.toggle()
        self.refreshStatus()
    }
    
    @objc private func showHelp(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: "https://custer.dev/support.html")!)
    }
    
    @objc private func showPrivacy(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(URL(string: "https://custer.dev/privacy.html")!)
    }
}
