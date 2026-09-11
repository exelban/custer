//
//  libs.swift
//  custer
//
//  Created by Serhiy Mytrovtsiy on 07/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import ServiceManagement
import AVFoundation

public struct LaunchAtLogin {
    private static let service = SMAppService.mainApp

    public static var isEnabled: Bool {
        get {
            service.status == .enabled
        }
        set {
            do {
                if newValue {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                print("LaunchAtLogin: failed to \(newValue ? "register" : "unregister"): \(error)")
            }
        }
    }
}

public class Store {
    static public let shared: Store = Store()
    
    private let defaults: UserDefaults
    
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    
    public func exist(key: String) -> Bool {
        return self.defaults.object(forKey: key) == nil ? false : true
    }
    
    public func bool(key: String, defaultValue value: Bool) -> Bool {
        return !self.exist(key: key) ? value : defaults.bool(forKey: key)
    }
    
    public func string(key: String, defaultValue value: String) -> String {
        return self.defaults.string(forKey: key) ?? value
    }
    
    public func float(key: String, defaultValue value: Float) -> Float {
        return (!self.exist(key: key) ? value : defaults.float(forKey: key))
    }
    
    public func data(key: String) -> Data? {
        return self.defaults.data(forKey: key)
    }
    
    public func set(key: String, value: Bool) {
        self.defaults.set(value, forKey: key)
    }
    
    public func set(key: String, value: String) {
        self.defaults.set(value, forKey: key)
    }
    
    public func set(key: String, value: Float) {
        self.defaults.set(value, forKey: key)
    }
    
    public func set(key: String, value: Data) {
        self.defaults.set(value, forKey: key)
    }
    
    public func remove(key: String) {
        self.defaults.removeObject(forKey: key)
    }
    
    public func reset() {
        self.defaults.dictionaryRepresentation().keys.forEach { key in
            self.defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Streams

public struct Stream: Codable, Equatable {
    public var name: String
    public var url: String
    
    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }
    
    /// Name to show in the UI: the user-given name, or the URL when no name is set.
    public var displayName: String {
        self.name.trimmingCharacters(in: .whitespaces).isEmpty ? self.url : self.name
    }
    
    /// Streams must be http(s) URLs with a host; anything else is rejected by the editor.
    public static func validate(url raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// All persisted user settings that concern streams. Replaces the former global `uri` and `streams` variables,
/// so that changing a value here has no hidden side effects on the player.
public final class Settings {
    public static let shared = Settings()
    
    private let store: Store
    
    public init(store: Store = .shared) {
        self.store = store
    }
    
    public var streams: [Stream] {
        get {
            guard let data = self.store.data(key: "streams"),
                  let list = try? JSONDecoder().decode([Stream].self, from: data) else {
                return []
            }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                self.store.set(key: "streams", value: data)
            }
        }
    }
    
    public var currentURL: String {
        get { self.store.string(key: "url", defaultValue: "") }
        set { self.store.set(key: "url", value: newValue) }
    }
    
    /// The selected stream, or a nameless stream built from the URL when the URL is not in the list.
    public var currentStream: Stream? {
        let url = self.currentURL
        guard !url.isEmpty else { return nil }
        return self.streams.first(where: { $0.url == url }) ?? Stream(name: "", url: url)
    }
    
    public var autoplay: Bool {
        get { self.store.bool(key: "autoplay", defaultValue: false) }
        set { self.store.set(key: "autoplay", value: newValue) }
    }
    
    /// Older versions stored a single URL only; turn it into a one-entry list.
    public func migrateLegacy() {
        if self.streams.isEmpty && !self.currentURL.isEmpty {
            self.streams = [Stream(name: "Stream", url: self.currentURL)]
        }
    }
}

public extension String {
    /// Shortens the string with a trailing ellipsis until it fits `width` points when drawn in `font`.
    func truncated(toWidth width: CGFloat, font: NSFont) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (self as NSString).size(withAttributes: attributes).width > width else { return self }
        
        var text = Substring(self)
        while !text.isEmpty {
            text = text.dropLast()
            let candidate = text.trimmingCharacters(in: .whitespaces) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= width {
                return candidate
            }
        }
        return "…"
    }
}

// https://stackoverflow.com/a/49434949
public extension AVPlayerItem {
    func totalBuffer() -> Double {
        return self.loadedTimeRanges
            .map({ $0.timeRangeValue })
            .reduce(0, { acc, cur in
                return acc + CMTimeGetSeconds(cur.duration)
            })
    }
    
    func currentBuffer() -> Double {
        let currentTime = self.currentTime()
        guard let timeRange = self.loadedTimeRanges.map({ $0.timeRangeValue }).first(where: { $0.containsTime(currentTime) }) else { return -1 }
        
        let behindBuffer = currentTime.seconds - CMTimeGetSeconds(timeRange.start)
        return max(behindBuffer, 0)
    }
}

public extension Double {
    /// Fixed-width clock style ("0:05", "12:34", "1:02:03") so a live-updating label keeps the same length.
    func clockString() -> String {
        let total = max(Int(self.rounded()), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    func secondsToHoursMinutesSeconds() -> (Int?, Int?, Int?) {
        let hrs = self / 3600
        let mins = (self.truncatingRemainder(dividingBy: 3600)) / 60
        let seconds = (self.truncatingRemainder(dividingBy:3600)).truncatingRemainder(dividingBy:60)
        return (Int(hrs) > 0 ? Int(hrs) : nil , Int(mins) > 0 ? Int(mins) : nil, Int(seconds) > 0 ? Int(seconds) : nil)
    }
    
    func printSecondsToHoursMinutesSeconds() -> String {
        let time = self.secondsToHoursMinutesSeconds()
        
        switch time {
        case (nil, let x? , let y?):
            return "\(x) min \(y) sec"
        case (nil, let x?, nil):
            return "\(x) min"
        case (let x?, nil, nil):
            return "\(x) h"
        case (nil, nil, let x?):
            return "\(x) sec"
        case (let x?, nil, let z?):
            return "\(x) h \(z) sec"
        case (let x?, let y?, nil):
            return "\(x) h \(y) min"
        case (let x?, let y?, let z?):
            return "\(x) h \(y) min \(z) sec"
        default:
            return "n/a"
        }
    }
}
