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
    
    private let defaults = UserDefaults.standard
    
    public init() {}
    
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
    
    public func set(key: String, value: Bool) {
        self.defaults.set(value, forKey: key)
    }
    
    public func set(key: String, value: String) {
        self.defaults.set(value, forKey: key)
    }
    
    public func set(key: String, value: Float) {
        self.defaults.set(value, forKey: key)
    }
    
    public func reset() {
        self.defaults.dictionaryRepresentation().keys.forEach { key in
            self.defaults.removeObject(forKey: key)
        }
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
