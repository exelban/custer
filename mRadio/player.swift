//
//  player.swift
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
import AVFoundation

internal enum player_state: Int {
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

internal enum player_error: String {
    case wrongURL = "wrong url provided"
    case emptyURL = "no url provided"
    case interrupted = "stream was interrupted"
}

protocol playerDelegate {
    func onError(error: String)
    func stateChange(state: player_state)
}

internal class Player: NSObject {
    public static let shared = Player()
    public var delegate: playerDelegate? = nil
    
    private var player = AVPlayer()
    private var observer: NSObjectProtocol?
    
    private var uri: String? = nil
    public var volume: Float = store.float(key: "volume", defaultValue: 0.8)
    private var volumeSet: Bool = false
    
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
    private var state: player_state = .undefined {
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
        
        os_log(.debug, log: log, "Initialized player")
    }
    
    deinit {
        guard self.observer != nil else {
            return
        }
        
        NotificationCenter.default.removeObserver(self.observer!)
    }
    
    private func streamInterrupted(notification: Notification) {
        os_log(.error, log: log, "%s", player_error.interrupted.rawValue)
        self.error = player_error.interrupted.rawValue
        self.state = .error
    }
    
    private func reset(play: Bool = false) {
        guard self.uri != nil else {
            self.error = player_error.emptyURL.rawValue
            self.state = .error
            return
        }
        
        self.error = nil
        
        guard let url = URL(string: self.uri!) else {
            self.error = player_error.wrongURL.rawValue
            self.state = .error
            return
        }
        
        let statusKey = "tracks"
        let asset: AVURLAsset = AVURLAsset(url: url, options: nil)
        asset.loadValuesAsynchronously(forKeys: [statusKey], completionHandler: {
            var error: NSError? = nil
            
            DispatchQueue.main.async {
                let status: AVKeyValueStatus = asset.statusOfValue(forKey: statusKey, error: &error)
                
                if status == AVKeyValueStatus.loaded {
                    self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    self.state = .ready
                    if !self.volumeSet {
                        self.player.volume = self.volume
                        self.volumeSet = true
                    }
                    if play {
                        self.play()
                    }
                    return
                }
                
                self.error = error!.localizedDescription
                self.state = .error
                os_log(.error, log: log, "load asset: %s", error!.localizedDescription)
            }
        })
    }
    
    public func play() {
        if self.state == .playing {
            return
        }
        
        self.player.play()
        self.state = .playing
        os_log(.debug, log: log, "player is playing")
    }
    
    public func pause() {
        if self.state != .playing {
            return
        }
        
        self.player.pause()
        self.state = .paused
        os_log(.debug, log: log, "player is paused")
    }
    
    public func setURL(_ uri: String) {
        self.uri = uri
        self.reset()
        
        os_log(.debug, log: log, "new url set: %s", uri)
    }
    
    public func isPlaying() -> Bool {
        return self.state == .playing
    }
    
    public func isError() -> Bool {
        return self.state == .error
    }
    
    public func setVolume(_ volume: Float) {
        self.player.volume = volume
    }
    
    public func clearBuffer() {
        self.reset(play: true)
    }
}
