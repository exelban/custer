//
//  main.swift
//  LaunchAtLogin
//
//  Created by Serhiy Mytrovtsiy on 07/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

func main() {
    let mainBundleId = Bundle.main.bundleIdentifier!.replacingOccurrences(of: ".LaunchAtLogin", with: "")
    
    if !NSRunningApplication.runningApplications(withBundleIdentifier: mainBundleId).isEmpty {
        exit(0)
    }
    
    let pathComponents = (Bundle.main.bundlePath as NSString).pathComponents
    let mainPath = NSString.path(withComponents: Array(pathComponents[0...(pathComponents.count - 5)]))
    NSWorkspace.shared.launchApplication(mainPath)
    
    exit(0)
}

main()
