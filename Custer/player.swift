//
//  player.swift
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
import AVFoundation
import MediaPlayer

internal enum PlayerState: Int {
    case undefined
    
    case error
    case ready
    
    case playing
    case paused
    case stopped
    
    public var description: String {
        switch self {
        case .undefined: return "undefined"
        case .error: return "error"
        case .ready: return "ready"
        case .playing: return "playing"
        case .paused: return "paused"
        case .stopped: return "stopped"
        }
    }
}

internal enum PlayerError: String {
    case wrongURL = "wrong url provided"
    case emptyURL = "no url provided"
    case interrupted = "stream was interrupted"
}

protocol PlayerDelegate: AnyObject {
    func onError(error: String)
    func stateChange(state: PlayerState)
}

// splits an ICY stream title ("Artist - Song") into artist and song name
internal func parseStreamTitle(_ raw: String?) -> (artist: String, title: String?) {
    // some radios use UPPERCASE titles -> Do Not Let Them Scream At Us
    var title = raw
    if let t = raw, t == t.uppercased() {
        title = t.capitalized
    }
    
    guard let t = title, t.contains(" - ") else {
        return ("", title)
    }
    
    let data = t.components(separatedBy: " - ")
    return (data[0], data[1...].joined(separator: " - "))
}

internal class Player: NSObject {
    public static let shared = Player()
    
    public weak var delegate: PlayerDelegate? = nil
    public var volume: Float {
        get {
            Store.shared.float(key: "volume", defaultValue: 0.8)
        }
        set {
            self.setVolume(newValue)
        }
    }
    public var buffer: (_ total: Double, _ current: Double) -> Void = {_,_ in }
    
    private var player = AVPlayer()
    private var observer: NSObjectProtocol?
    private var bufferObserver: Any? = nil
    private var bufferObserverOwner: AVPlayer? = nil
    private var metadataOutput: AVPlayerItemMetadataOutput?
    
    private var uri: String? = nil
    private var pauseTimestamp: Date? = nil
    private var resetGeneration: Int = 0
    
    private let nowPlayingInfoCenter: MPNowPlayingInfoCenter = .default()
    private let remoteCommandCenter: MPRemoteCommandCenter = .shared()
    
    private var error: String? = nil {
        didSet {
            guard self.error != nil else {
                return
            }
            
            if let delegate = self.delegate {
                delegate.onError(error: self.error!)
            }
        }
    }
    
    private var state: PlayerState = .undefined {
        didSet {
            if let delegate = self.delegate {
                delegate.stateChange(state: self.state)
            }
        }
    }
    
    override init() {
        super.init()
        
        self.reset()
        
        self.observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: nil,
            using: streamInterrupted
        )
        
        self.remoteCommandCenter.playCommand.addTarget(self, action: #selector(self.playCommandEvent))
        self.remoteCommandCenter.pauseCommand.addTarget(self, action: #selector(self.pauseCommandEvent))
        self.remoteCommandCenter.stopCommand.addTarget(self, action: #selector(self.stopCommandEvent))
        self.remoteCommandCenter.togglePlayPauseCommand.addTarget(self, action: #selector(self.playPauseCommandEvent))
        
        os_log(.debug, log: log, "Initialized player")
    }
    
    deinit {
        self.removeObservers()
        
        self.remoteCommandCenter.playCommand.removeTarget(self)
        self.remoteCommandCenter.pauseCommand.removeTarget(self)
        self.remoteCommandCenter.stopCommand.removeTarget(self)
        self.remoteCommandCenter.togglePlayPauseCommand.removeTarget(self)

        if self.observer != nil {
            NotificationCenter.default.removeObserver(self.observer!)
        }
    }
    
    private func removeObservers() {
        if let output = self.metadataOutput {
            self.player.currentItem?.remove(output)
            self.metadataOutput = nil
        }
        
        self.removeBufferObserver()
    }
    
    private func removeBufferObserver() {
        if let observer = self.bufferObserver, let owner = self.bufferObserverOwner {
            owner.removeTimeObserver(observer)
        }
        self.bufferObserver = nil
        self.bufferObserverOwner = nil
    }
    
    private func streamInterrupted(notification: Notification) {
        guard self.state == .playing else { return }
        os_log(.error, log: log, "%s", PlayerError.interrupted.rawValue)
        self.error = PlayerError.interrupted.rawValue
        self.state = .error
    }
    
    public func reset(play: Bool = false) {
        guard let uri = self.uri else {
            self.error = PlayerError.emptyURL.rawValue
            self.state = .error
            return
        }
        
        self.error = nil
        
        guard let url = URL(string: uri) else {
            self.error = PlayerError.wrongURL.rawValue
            self.state = .error
            return
        }
        
        self.removeObservers()
        
        self.resetGeneration += 1
        let generation = self.resetGeneration
        
        let asset = AVURLAsset(url: url)
        Task { [weak self, play] in
            do {
                let _ = try await asset.load(.tracks)
                await self?.setupPlayer(asset: asset, play: play, generation: generation)
            } catch {
                await self?.handleLoadError(error, generation: generation)
            }
        }
    }
    
    @MainActor
    private func setupPlayer(asset: AVURLAsset, play: Bool, generation: Int) {
        // a newer reset() or stop() superseded this load, discard it
        guard generation == self.resetGeneration else { return }
        
        let playerItem = AVPlayerItem(asset: asset)
        
        let output = AVPlayerItemMetadataOutput()
        output.setDelegate(self, queue: .main)
        playerItem.add(output)
        self.metadataOutput = output
        
        self.player = AVPlayer(playerItem: playerItem)
        self.state = .ready
        self.player.volume = self.volume
        
        if play {
            self.play()
        }
    }
    
    @MainActor
    private func handleLoadError(_ error: Error, generation: Int) {
        guard generation == self.resetGeneration else { return }
        
        self.error = error.localizedDescription
        self.state = .error
        os_log(.error, log: log, "load asset: %s", error.localizedDescription)
    }
    
    public func play() {
        if self.state == .playing {
            return
        }
        
        if self.pauseTimestamp != nil && abs(self.pauseTimestamp!.timeIntervalSinceNow) > 60*3 {
            self.pauseTimestamp = nil
            self.reset(play: true)
            return
        }
        
        self.player.play()
        self.player.volume = self.volume
        
        self.state = .playing
        os_log(.debug, log: log, "player is playing")
        
        self.removeBufferObserver()
        let owner = self.player
        self.bufferObserver = owner.addPeriodicTimeObserver(forInterval: CMTimeMake(value: 1, timescale: 10), queue: DispatchQueue.main) { [weak self] time in
            self?.buffer(self?.player.currentItem?.totalBuffer() ?? -1, self?.player.currentItem?.currentBuffer() ?? -1)
        }
        self.bufferObserverOwner = owner
        
        self.nowPlayingInfoCenter.playbackState = .playing
    }
    
    public func pause() {
        if self.state != .playing {
            return
        }
        
        self.player.pause()
        self.state = .paused
        self.pauseTimestamp = Date()
        
        self.nowPlayingInfoCenter.playbackState = .paused

        os_log(.debug, log: log, "player is paused")
    }
    
    public func stop() {
        self.resetGeneration += 1
        self.removeObservers()
        
        self.player.pause()
        self.player.replaceCurrentItem(with: nil)
        self.pauseTimestamp = nil
        self.state = .stopped
        
        self.nowPlayingInfoCenter.playbackState = .stopped
        
        os_log(.debug, log: log, "player is stopped")
    }
    
    public func setURL(_ uri: String) {
        guard uri != "" else {
            os_log(.debug, log: log, "url cleared, stopping the player")
            self.uri = nil
            self.stop()
            return
        }
        
        self.uri = uri
        self.reset()
        
        os_log(.debug, log: log, "new url set: %s", uri)
    }
    
    public func setVolume(_ value: Float, persist: Bool = true) {
        self.player.volume = value
        if persist {
            Store.shared.set(key: "volume", value: value)
        }
    }
    
    public func isPlaying() -> Bool {
        return self.state == .playing && self.player.rate == 1
    }
    
    public func isError() -> Bool {
        return self.state == .error
    }
    
    public func clearBuffer() {
        self.reset(play: true)
    }
    
    private func setMetadata(title: String?) {
        var info = self.nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()
        
        let parsed = parseStreamTitle(title)
        info[MPMediaItemPropertyTitle] = parsed.title ?? "Custer Radio"
        info[MPMediaItemPropertyArtist] = parsed.artist
        info[MPNowPlayingInfoPropertyIsLiveStream] = 1.0
        
        DispatchQueue.main.async { [weak self] in
            self?.nowPlayingInfoCenter.nowPlayingInfo = info
            self?.nowPlayingInfoCenter.playbackState = .playing
        }
    }
    
    // MARK:- command handlers
    
    @objc func playCommandEvent(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        self.play()
        return .success
    }
    
    @objc func pauseCommandEvent(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        self.pause()
        return .success
    }
    
    @objc func stopCommandEvent(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        self.pause()
        return .success
    }
    
    @objc func playPauseCommandEvent(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        if self.isPlaying() {
            self.pause()
        } else {
            self.play()
        }
        return .success
    }
}

// MARK: - AVPlayerItemMetadataOutputPushDelegate

extension Player: AVPlayerItemMetadataOutputPushDelegate {
    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        for group in groups {
            for item in group.items {
                Task { [weak self] in
                    guard let title = try? await item.load(.stringValue) else { return }
                    self?.setMetadata(title: title)
                }
            }
        }
    }
}
