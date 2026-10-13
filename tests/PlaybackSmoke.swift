//
//  PlaybackSmoke.swift
//  custer
//

import AVFoundation
import Foundation

/// Optional live check. Muted playback verifies media progression, not speaker output.
@main
struct PlaybackSmoke {
    @MainActor
    static func main() async throws {
        guard let address = CommandLine.arguments.dropFirst().first, let url = URL(string: address) else {
            fatalError("Pass a radio URL")
        }

        let candidates = try await StreamResolver.resolve(url)
        print("Resolved \(candidates.count) media candidates")

        for candidate in candidates {
            let player = AVPlayer(url: candidate)
            player.isMuted = true
            defer {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }

            player.play()
            for _ in 0..<80 {
                try await Task.sleep(nanoseconds: 250_000_000)
                if player.currentItem?.status == .failed {
                    break
                }
                if player.timeControlStatus == .playing && player.currentTime().seconds >= 2 {
                    print("Muted AVPlayer playback advanced beyond two seconds")
                    return
                }
            }
        }

        throw NSError(domain: "PlaybackSmoke", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "No candidate produced advancing playback"])
    }
}
