# Custer

<a href="https://github.com/exelban/custer/releases"><p align="center"><img src="https://github.com/exelban/custer/blob/master/Custer/Supporting%20Files/Assets.xcassets/AppIcon.appiconset/icon.png?raw=true" width="120"></p></a>

<p align="center"><a href="https://apps.apple.com/app/custer/id1532303390?mt=12"><img src="site/mac-app-store.svg" alt="Download on the Mac App Store" height="40"></a></p>

macOS streaming radio in your menu bar

## Installation
### App Store
You can download Custer from the [App Store](https://apps.apple.com/app/custer/id1532303390?mt=12).

### Manually
You can download the latest version [here](https://github.com/exelban/custer/releases).  
Download the file called `Custer.dmg`. Open it and move the app to the application folder.

## Requirements
Custer supported on macOS 14.6 (Sonoma) and higher.

## Features
Custer is an application that allows you to listen to your favorite internet radio and control it from the menu bar.

 - Simple and lightweight
 - Choose the left-click action: play/pause (GitHub default) or open the menu (App Store default). Right-click or Control-click always opens the menu; scroll changes volume.
 - Direct audio, M3U/PLS playlists, and HLS streams
 - Multiple streams with quick switching (⌘1–⌘9 in the menu)
 - Shows the current song title in the menu and tooltip, with one click to copy it
 - Autoplay on launch
 - Volume control and mute
 - Control with media keys
 - Now Playing integration (track info and artwork in Control Center)
 - Automatic pause/resume on sleep/wake and when the network drops
 - Automatic reconnect with backoff when a stream stalls or fails

## Building and distribution

Both editions share the player and settings UI and use the bundle identifier `eu.exelban.custer`. The `Custer` scheme builds the GitHub edition with its updater. The `Custer App Store` scheme builds the sandboxed edition without updater code or scripts.

- `make test`: playlist HTTP fixtures and preference tests for both editions.
- `make verify-builds`: build both universal Release variants and check their contents.
- `make release-github`: archive, Developer ID export, notarize, and package `Custer.dmg`.
- `make release-appstore`: archive, verify, and upload to App Store Connect; does not submit for review or publish.

Set **Version** and **Build** under **General → Identity** for each target in Xcode. Keep both targets on the same values for a paired release. Distribution requires your Apple signing credentials.

## License
[MIT License](https://github.com/exelban/custer/blob/master/LICENSE)
