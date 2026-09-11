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
    case loading
    case ready
    
    case playing
    case paused
    case stopped
    
    public var description: String {
        switch self {
        case .undefined: return "undefined"
        case .error: return "error"
        case .loading: return "loading"
        case .ready: return "ready"
        case .playing: return "playing"
        case .paused: return "paused"
        case .stopped: return "stopped"
        }
    }
}

internal enum PlayerError: String, LocalizedError {
    case wrongURL = "wrong url provided"
    case emptyURL = "no url provided"
    case interrupted = "stream was interrupted"
    case stalled = "stream stopped delivering data"
    case timeout = "stream did not respond in time"
    
    var errorDescription: String? { self.rawValue }
}

@MainActor
protocol PlayerDelegate: AnyObject {
    /// `userInitiated` is true when the failed action was triggered directly by the user (click, menu, media key).
    /// Automatic actions (wake, reconnect, network change) report errors silently.
    func onError(error: String, userInitiated: Bool)
    func stateChange(state: PlayerState)
    /// Something shown in the UI changed that is not a state change: song title, stream name, reconnect scheduling.
    func infoChange()
}

// MARK: - stream title helpers

/// Some radios send titles in ALL CAPS. Capitalize those, but leave tokens that contain digits or
/// punctuation alone (AC/DC, U2, R.E.M.) since those are usually written that way on purpose.
internal func normalizeStreamTitle(_ raw: String) -> String {
    let letters = raw.filter { $0.isLetter }
    guard letters.count >= 4, letters == letters.uppercased(), letters != letters.lowercased() else {
        return raw
    }
    
    return raw.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
        let w = String(word)
        let isPlainWord = w.allSatisfy { $0.isLetter }
        return isPlainWord ? w.capitalized : w
    }.joined(separator: " ")
}

/// Splits an ICY stream title ("Artist - Song") into artist and song name.
internal func parseStreamTitle(_ raw: String?) -> (artist: String, title: String?) {
    guard let raw = raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
        return ("", nil)
    }
    
    let title = normalizeStreamTitle(raw)
    guard title.contains(" - ") else {
        return ("", title)
    }
    
    let data = title.components(separatedBy: " - ")
    return (data[0], data[1...].joined(separator: " - "))
}

// MARK: - Player

@MainActor
internal class Player: NSObject {
    public static let shared = Player()
    
    public weak var delegate: PlayerDelegate? = nil
    
    /// Asked before scheduling an automatic reconnect; when the network is down the player waits for
    /// `resumeIfNeeded()` instead of retrying blindly.
    public var isNetworkReachable: () -> Bool = { true }
    
    public var volume: Float {
        get { Store.shared.float(key: "volume", defaultValue: 0.8) }
        set { self.setVolume(newValue) }
    }
    
    public var isMuted: Bool {
        get { Store.shared.bool(key: "muted", defaultValue: false) }
        set {
            Store.shared.set(key: "muted", value: newValue)
            self.player.isMuted = newValue
        }
    }
    
    public private(set) var state: PlayerState = .undefined {
        didSet {
            guard oldValue != self.state else { return }
            self.delegate?.stateChange(state: self.state)
            self.updateNowPlaying()
        }
    }
    
    /// The song title reported by the stream (already normalized), nil when the stream sends none.
    public private(set) var currentTitle: String? = nil
    
    /// The last error message, kept for the menu status line.
    public private(set) var lastError: String? = nil
    
    /// True while the user wants audio: set by play(), cleared by pause()/stop().
    /// Sleep and network loss keep it, which is what lets playback resume afterwards.
    public private(set) var wantsToPlay: Bool = false
    
    public private(set) var stream: Stream? = nil
    
    private var player = AVPlayer()
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemObservers: [NSObjectProtocol] = []
    private var metadataOutput: AVPlayerItemMetadataOutput?
    
    private var pauseTimestamp: Date? = nil
    private var generation: Int = 0
    private var loadTask: Task<Void, Never>? = nil
    private var playWhenReady: Bool = false
    
    private var reconnectAttempt: Int = 0
    private var reconnectTimer: Timer? = nil
    private var stallTimer: Timer? = nil
    private var isBuffering: Bool = false
    
    private let nowPlayingInfoCenter: MPNowPlayingInfoCenter = .default()
    private let remoteCommandCenter: MPRemoteCommandCenter = .shared()
    private lazy var artwork: MPMediaItemArtwork? = {
        guard let image = NSApp.applicationIconImage else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }()
    
    private static let loadTimeout: TimeInterval = 15
    private static let stallTimeout: TimeInterval = 20
    private static let resumeAfterPauseLimit: TimeInterval = 60 * 3
    private static let maxReconnectDelay: TimeInterval = 60
    
    override init() {
        super.init()
        
        self.remoteCommandCenter.playCommand.addTarget(self, action: #selector(self.playCommandEvent))
        self.remoteCommandCenter.pauseCommand.addTarget(self, action: #selector(self.pauseCommandEvent))
        self.remoteCommandCenter.stopCommand.addTarget(self, action: #selector(self.stopCommandEvent))
        self.remoteCommandCenter.togglePlayPauseCommand.addTarget(self, action: #selector(self.playPauseCommandEvent))
        
        os_log(.debug, log: log, "Initialized player")
    }
    
    // MARK: - public API
    
    /// Selects the stream to play. Passing nil (or an empty URL) stops the player.
    public func setStream(_ stream: Stream?, play: Bool) {
        guard let stream = stream, !stream.url.isEmpty else {
            os_log(.debug, log: log, "url cleared, stopping the player")
            self.stream = nil
            self.stop()
            return
        }
        
        self.stream = stream
        self.currentTitle = nil
        self.delegate?.infoChange()
        self.reconnectAttempt = 0
        
        os_log(.debug, log: log, "new stream set: %s", stream.url)
        self.reset(play: play, userInitiated: true)
    }
    
    /// Updates the name shown for the current stream without touching playback.
    public func updateStreamInfo(_ stream: Stream) {
        guard self.stream?.url == stream.url else { return }
        self.stream = stream
        self.updateNowPlaying()
        self.delegate?.infoChange()
    }
    
    public func play(userInitiated: Bool = true) {
        self.wantsToPlay = true
        if userInitiated {
            self.reconnectAttempt = 0
            self.cancelReconnect()
        }
        
        switch self.state {
        case .playing:
            return
        case .loading:
            self.playWhenReady = true
            if self.player.currentItem != nil && self.player.timeControlStatus == .paused {
                self.player.play()
            }
            return
        case .error, .stopped, .undefined:
            self.reset(play: true, userInitiated: userInitiated)
            return
        case .paused:
            // a live stream that was paused for a long time is far behind; reconnect instead of replaying the buffer
            if let ts = self.pauseTimestamp, abs(ts.timeIntervalSinceNow) > Player.resumeAfterPauseLimit {
                self.pauseTimestamp = nil
                self.reset(play: true, userInitiated: userInitiated)
                return
            }
        case .ready:
            break
        }
        
        guard self.player.currentItem != nil else {
            // suspended while loading, nothing to resume: connect again
            self.reset(play: true, userInitiated: userInitiated)
            return
        }
        
        self.pauseTimestamp = nil
        self.player.volume = self.volume
        self.player.isMuted = self.isMuted
        self.player.play()
        
        // the KVO on timeControlStatus moves us to .playing once audio actually flows
        self.state = .loading
        self.startStallTimer()
        os_log(.debug, log: log, "player is playing")
    }
    
    public func pause(userInitiated: Bool = true) {
        if userInitiated {
            self.wantsToPlay = false
            self.cancelReconnect()
        }
        self.stopStallTimer()
        
        switch self.state {
        case .playing:
            break
        case .loading:
            self.playWhenReady = false
            if self.player.currentItem == nil {
                // still loading the asset: drop the load, a later play() reconnects
                self.cancelLoad()
                self.state = .stopped
                return
            }
        default:
            return
        }
        
        self.player.pause()
        self.state = .paused
        self.pauseTimestamp = Date()
        os_log(.debug, log: log, "player is paused")
    }
    
    /// Left click / media key toggle.
    public func toggle() {
        if self.state == .playing || (self.state == .loading && self.wantsToPlay) {
            self.pause()
        } else {
            self.play()
        }
    }
    
    public func stop() {
        self.wantsToPlay = false
        self.cancelReconnect()
        self.cancelLoad()
        self.teardownPlayer()
        
        self.pauseTimestamp = nil
        self.currentTitle = nil
        self.delegate?.infoChange()
        self.state = .stopped
        
        self.nowPlayingInfoCenter.nowPlayingInfo = nil
        self.nowPlayingInfoCenter.playbackState = .stopped
        os_log(.debug, log: log, "player is stopped")
    }
    
    /// Drops the current connection and opens a fresh one at the live edge.
    public func reconnect() {
        guard self.stream != nil else { return }
        self.reset(play: self.wantsToPlay || self.state == .playing, userInitiated: true)
    }
    
    /// Called before sleep or when the network goes away: pauses without forgetting whether the user wanted audio.
    public func suspend() {
        self.cancelReconnect()
        self.stopStallTimer()
        
        guard self.state == .playing || self.state == .loading else { return }
        
        self.cancelLoad()
        self.teardownPlayer()
        self.state = self.wantsToPlay ? .paused : .stopped
        self.pauseTimestamp = Date()
        os_log(.debug, log: log, "player suspended (wantsToPlay: %d)", self.wantsToPlay)
    }
    
    /// Called after wake or when the network is back. Resumes when the user wanted audio,
    /// or reloads a stream that was left in the error state.
    public func resumeIfNeeded() {
        guard self.stream != nil else { return }
        
        if self.wantsToPlay {
            os_log(.debug, log: log, "resuming playback")
            self.reset(play: true, userInitiated: false)
        } else if self.state == .error {
            self.reset(play: false, userInitiated: false)
        }
    }
    
    public func setVolume(_ value: Float, persist: Bool = true) {
        let clamped = min(max(value, 0), 1)
        self.player.volume = clamped
        if persist {
            Store.shared.set(key: "volume", value: clamped)
        }
    }
    
    public func isPlaying() -> Bool {
        return self.state == .playing
    }
    
    public func isError() -> Bool {
        return self.state == .error
    }
    
    /// Seconds of audio between the live edge and what is playing right now, nil when not playing.
    public func secondsBehindLive() -> Double? {
        guard self.state == .playing, let item = self.player.currentItem else { return nil }
        let lag = item.currentBuffer()
        return lag < 0 ? nil : lag
    }
    
    // MARK: - loading
    
    private func reset(play: Bool, userInitiated: Bool) {
        guard let stream = self.stream else {
            self.fail(PlayerError.emptyURL, userInitiated: userInitiated)
            return
        }
        guard let url = URL(string: stream.url), url.scheme != nil else {
            self.fail(PlayerError.wrongURL, userInitiated: userInitiated)
            return
        }
        
        // stop whatever is playing right now; the old item must not keep playing while the new one loads
        self.cancelLoad()
        self.teardownPlayer()
        
        self.lastError = nil
        self.playWhenReady = play
        if play {
            self.wantsToPlay = true
        }
        self.state = .loading
        
        self.generation += 1
        let generation = self.generation
        let asset = AVURLAsset(url: url)
        
        self.loadTask = Task { [weak self] in
            do {
                try await Player.load(asset: asset, timeout: Player.loadTimeout)
                guard !Task.isCancelled else { return }
                self?.setupPlayer(asset: asset, generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                self?.handleLoadError(error, generation: generation, userInitiated: userInitiated)
            }
        }
    }
    
    /// Loads the asset tracks, giving up after `timeout` seconds so a silent server cannot hang the player forever.
    private static func load(asset: AVURLAsset, timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await asset.load(.tracks)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw PlayerError.timeout
            }
            
            do {
                try await group.next()
            } catch {
                asset.cancelLoading()
                group.cancelAll()
                throw error
            }
            group.cancelAll()
        }
    }
    
    private func setupPlayer(asset: AVURLAsset, generation: Int) {
        // a newer reset() or stop() superseded this load, discard it
        guard generation == self.generation else { return }
        
        let playerItem = AVPlayerItem(asset: asset)
        
        let output = AVPlayerItemMetadataOutput()
        output.setDelegate(self, queue: .main)
        playerItem.add(output)
        self.metadataOutput = output
        
        let player = AVPlayer(playerItem: playerItem)
        player.volume = self.volume
        player.isMuted = self.isMuted
        self.player = player
        self.observe(player: player, item: playerItem, generation: generation)
        
        self.state = .ready
        
        if self.playWhenReady {
            self.playWhenReady = false
            self.play(userInitiated: false)
        }
    }
    
    private func handleLoadError(_ error: Error, generation: Int, userInitiated: Bool) {
        guard generation == self.generation else { return }
        os_log(.error, log: log, "load asset: %s", error.localizedDescription)
        self.fail(error, userInitiated: userInitiated)
    }
    
    private func cancelLoad() {
        self.loadTask?.cancel()
        self.loadTask = nil
        self.generation += 1
    }
    
    private func teardownPlayer() {
        self.stopStallTimer()
        self.timeControlObservation = nil
        self.itemStatusObservation = nil
        self.itemObservers.forEach { NotificationCenter.default.removeObserver($0) }
        self.itemObservers = []
        
        if let output = self.metadataOutput {
            self.player.currentItem?.remove(output)
            self.metadataOutput = nil
        }
        
        self.player.pause()
        self.player.replaceCurrentItem(with: nil)
        self.isBuffering = false
    }
    
    // MARK: - playback monitoring
    
    private func observe(player: AVPlayer, item: AVPlayerItem, generation: Int) {
        self.timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                self?.timeControlChanged(status, generation: generation)
            }
        }
        
        self.itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let error = item.error ?? PlayerError.interrupted
            Task { @MainActor in
                self?.playbackFailed(error, generation: generation)
            }
        }
        
        let center = NotificationCenter.default
        self.itemObservers = [
            center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
                let error = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error) ?? PlayerError.interrupted
                Task { @MainActor in
                    self?.playbackFailed(error, generation: generation)
                }
            },
            center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.playbackStalled(generation: generation)
                }
            },
        ]
    }
    
    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus, generation: Int) {
        guard generation == self.generation else { return }
        
        switch status {
        case .playing:
            self.isBuffering = false
            self.stopStallTimer()
            self.reconnectAttempt = 0
            self.lastError = nil
            if self.state == .loading || self.state == .playing {
                self.state = .playing
            }
        case .waitingToPlayAtSpecifiedRate:
            self.isBuffering = true
            if self.state == .playing {
                self.state = .loading
                self.startStallTimer()
            }
        case .paused:
            self.isBuffering = false
        @unknown default:
            break
        }
    }
    
    private func playbackStalled(generation: Int) {
        guard generation == self.generation, self.wantsToPlay else { return }
        os_log(.debug, log: log, "playback stalled, waiting for data")
        if self.state == .playing {
            self.state = .loading
        }
        self.startStallTimer()
    }
    
    private func playbackFailed(_ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        guard self.state == .playing || self.state == .loading || self.state == .ready else { return }
        os_log(.error, log: log, "playback failed: %s", error.localizedDescription)
        
        self.teardownPlayer()
        self.fail(error, userInitiated: false)
    }
    
    /// Moves to the error state, tells the delegate, and schedules a reconnect when the user still wants audio.
    private func fail(_ error: Error, userInitiated: Bool) {
        let message = error.localizedDescription
        self.lastError = message
        self.state = .error
        self.delegate?.onError(error: message, userInitiated: userInitiated)
        
        if let playerError = error as? PlayerError, playerError == .emptyURL || playerError == .wrongURL {
            return // nothing to retry
        }
        self.scheduleReconnect()
    }
    
    // MARK: - stall / reconnect
    
    private func startStallTimer() {
        self.stopStallTimer()
        self.stallTimer = Timer.scheduledTimer(timeInterval: Player.stallTimeout, target: self, selector: #selector(self.stallTimerFired), userInfo: nil, repeats: false)
    }
    
    private func stopStallTimer() {
        self.stallTimer?.invalidate()
        self.stallTimer = nil
    }
    
    @objc private func stallTimerFired() {
        self.stallTimer = nil
        guard self.wantsToPlay, self.state == .loading, self.player.currentItem != nil else { return }
        os_log(.error, log: log, "%s", PlayerError.stalled.rawValue)
        self.teardownPlayer()
        self.fail(PlayerError.stalled, userInitiated: false)
    }
    
    private func scheduleReconnect() {
        self.cancelReconnect()
        guard self.wantsToPlay, self.stream != nil else { return }
        guard self.isNetworkReachable() else {
            os_log(.debug, log: log, "offline, reconnect deferred until the network is back")
            return
        }
        
        self.reconnectAttempt += 1
        let delay = min(pow(2.0, Double(self.reconnectAttempt)), Player.maxReconnectDelay)
        os_log(.debug, log: log, "reconnect attempt %d in %.0f s", self.reconnectAttempt, delay)
        
        self.reconnectTimer = Timer.scheduledTimer(timeInterval: delay, target: self, selector: #selector(self.reconnectTimerFired), userInfo: nil, repeats: false)
        self.delegate?.infoChange()
    }
    
    private func cancelReconnect() {
        self.reconnectTimer?.invalidate()
        self.reconnectTimer = nil
    }
    
    @objc private func reconnectTimerFired() {
        self.reconnectTimer = nil
        guard self.wantsToPlay, self.state == .error else { return }
        self.reset(play: true, userInitiated: false)
    }
    
    /// True while an automatic reconnect is pending.
    public var isReconnecting: Bool {
        self.reconnectTimer != nil || (self.state == .error && self.wantsToPlay && !self.isNetworkReachable())
    }
    
    // MARK: - Now Playing
    
    private func updateNowPlaying() {
        guard self.stream != nil else { return }
        
        let streamName = self.stream?.displayName ?? "Custer"
        let parsed = parseStreamTitle(self.currentTitle)
        
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = parsed.title ?? streamName
        info[MPMediaItemPropertyArtist] = parsed.artist.isEmpty ? (parsed.title == nil ? "" : streamName) : parsed.artist
        info[MPMediaItemPropertyAlbumTitle] = parsed.title == nil ? "" : streamName
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = self.state == .playing ? 1.0 : 0.0
        if let artwork = self.artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        
        self.nowPlayingInfoCenter.nowPlayingInfo = info
        switch self.state {
        case .playing, .loading: self.nowPlayingInfoCenter.playbackState = .playing
        case .paused, .ready: self.nowPlayingInfoCenter.playbackState = .paused
        default: self.nowPlayingInfoCenter.playbackState = .stopped
        }
    }
    
    private func setTitle(_ raw: String?) {
        let title = raw.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : normalizeStreamTitle($0) }
        guard title != self.currentTitle else { return }
        self.currentTitle = title
        self.updateNowPlaying()
        self.delegate?.infoChange()
    }
    
    // MARK: - remote command handlers
    
    @objc nonisolated private func playCommandEvent(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in self.play() }
        return .success
    }
    
    @objc nonisolated private func pauseCommandEvent(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in self.pause() }
        return .success
    }
    
    @objc nonisolated private func stopCommandEvent(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in self.pause() }
        return .success
    }
    
    @objc nonisolated private func playPauseCommandEvent(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in self.toggle() }
        return .success
    }
}

// MARK: - AVPlayerItemMetadataOutputPushDelegate

extension Player: AVPlayerItemMetadataOutputPushDelegate {
    nonisolated func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        // only the StreamTitle entry carries the song; ignore StreamUrl and friends so they cannot overwrite it
        let items = groups.flatMap { $0.items }.filter { $0.identifier == .icyMetadataStreamTitle }
        guard let item = items.last else { return }
        
        Task { [weak self] in
            guard let title = try? await item.load(.stringValue) else { return }
            await self?.setTitle(title)
        }
    }
}
