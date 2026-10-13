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
#if !APP_STORE
import Updater
#endif

let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "custer")

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar: MenuBar = MenuBar()
    #if !APP_STORE
    private let updater = AppDelegate.makeUpdater()
    
    nonisolated private static func makeUpdater() -> Updater {
        return Updater(name: "Custer", providers: [Updater.Github(user: "exelban", repo: "custer", asset: "Custer.dmg")])
    }
    #endif
    private let reachability = Reachability()
    
    private let nc = NSWorkspace.shared.notificationCenter
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        #if !APP_STORE
        self.updater.cleanup()
        #endif
        
        Settings.shared.migrateLegacy()
        
        Player.shared.delegate = self
        Player.shared.isNetworkReachable = { [weak self] in self?.reachability.isConnected ?? true }
        
        self.menuBar.menu.actions = self
        self.menuBar.menu.rebuild()
        
        self.networkReachability()
        #if !APP_STORE
        self.checkForNewVersion()
        #endif
        
        nc.addObserver(self, selector: #selector(AppDelegate.onDidWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(AppDelegate.onWillSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        
        if let stream = Settings.shared.currentStream {
            Player.shared.setStream(stream, play: Settings.shared.autoplay)
        } else {
            os_log(.debug, log: log, "Stream url is not defined")
            Player.shared.setStream(nil, play: false)
            self.menuBar.menu.showAddressView()
        }
    }
    
    deinit {
        nc.removeObserver(self)
    }
    
    @objc func onWillSleep() {
        os_log(.debug, log: log, "Going to sleep, suspend playback")
        Player.shared.suspend()
    }

    @objc func onDidWake() {
        os_log(.debug, log: log, "Resumed from sleep, resume playback if needed")
        Player.shared.resumeIfNeeded()
    }
}

// MARK: - PlayerDelegate

extension AppDelegate: PlayerDelegate {
    func onError(error: String, userInitiated: Bool) {
        os_log(.error, log: log, "error: %s", error)
        self.menuBar.menu.refreshStatus()
        
        // automatic actions (wake, reconnect, network change) must not pop dialogs in front of the user
        guard userInitiated, self.reachability.isConnected else { return }
        
        let name = Player.shared.stream?.displayName ?? "the stream"
        let alert = NSAlert()
        alert.messageText = "Could not play \(name)"
        alert.informativeText = error.prefix(1).uppercased() + error.dropFirst() + "."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        
        NSApplication.shared.activate()
        alert.runModal()
    }
    
    func stateChange(state: PlayerState) {
        os_log(.debug, log: log, "new state: %s", state.description)
        self.menuBar.setState(state)
        self.menuBar.menu.refreshStatus()
    }
    
    func infoChange() {
        self.menuBar.refreshTooltip()
        self.menuBar.menu.refreshStatus()
    }
}

// MARK: - MenuActions

extension AppDelegate: MenuActions {
    func select(stream: Stream) {
        Settings.shared.currentURL = stream.url
        Player.shared.setStream(stream, play: true)
    }
    
    func save(stream: Stream, at index: Int?) {
        var list = Settings.shared.streams
        let wasCurrent: Bool
        
        if let i = index, i >= 0 && i < list.count {
            wasCurrent = list[i].url == Settings.shared.currentURL
            list[i] = stream
        } else {
            wasCurrent = false
            list.append(stream)
        }
        Settings.shared.streams = list
        
        if wasCurrent {
            Settings.shared.currentURL = stream.url
            let player = Player.shared
            if player.stream?.url == stream.url {
                player.updateStreamInfo(stream) // only the name changed, keep playing
            } else {
                player.setStream(stream, play: player.wantsToPlay)
            }
        } else if Settings.shared.currentURL.isEmpty {
            // the very first stream: select it and start listening right away
            self.select(stream: stream)
        }
    }
    
    func remove(streamAt index: Int) {
        var list = Settings.shared.streams
        guard index >= 0 && index < list.count else { return }
        let removed = list.remove(at: index)
        Settings.shared.streams = list
        
        guard removed.url == Settings.shared.currentURL else { return }
        
        let player = Player.shared
        if let next = list.first {
            Settings.shared.currentURL = next.url
            player.setStream(next, play: player.wantsToPlay)
        } else {
            Settings.shared.currentURL = ""
            player.setStream(nil, play: false)
        }
    }
}

// MARK: - helpers

extension AppDelegate {
    #if !APP_STORE
    private func checkForNewVersion() {
        // The package waits synchronously for its providers; keep launch/playback responsive.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let updater = AppDelegate.makeUpdater()
            updater.check() { result, error in
                Task { @MainActor in
                    self?.handleUpdateResult(result, error: error)
                }
            }
        }
    }
    
    private func handleUpdateResult(_ result: Updater.Release?, error: [Error]?) {
        if let errors = error, !errors.isEmpty {
            os_log(.error, log: log, "error updater.check(): %s", "\(errors)")
            return
        }
        
        guard let external = result else {
            os_log(.error, log: log, "no external release found")
            return
        }
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            os_log(.error, log: log, "missing CFBundleShortVersionString")
            return
        }
        let local = Updater.Tag("v\(version)")
        
        if local >= external.tag {
            return
        }
        
        os_log(.debug, log: log, "show update window because new version of app found: %s", "\(external.tag.raw)")
        
        let alert = NSAlert()
        alert.messageText = "New version available"
        alert.informativeText = "Current version:   \(local.raw)\nLatest version:     \(external.tag.raw)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        
        NSApplication.shared.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: external.url) {
                self.updater.download(url, done: { path in
                    self.updater.install(path: path)
                })
            }
        }
    }
    
    #endif
    
    private func networkReachability() {
        self.reachability.whenReachable = {
            os_log(.debug, log: log, "network is reachable")
            Player.shared.resumeIfNeeded()
        }
        self.reachability.whenUnreachable = {
            os_log(.debug, log: log, "network is unreachable")
            Player.shared.suspend()
        }
        
        self.reachability.start()
    }
}
