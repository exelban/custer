//
//  StreamResolverTests.swift
//  custer
//

import Foundation

@main
struct StreamResolverTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() async throws {
        let base = URL(string: "https://radio.example/lists/station.m3u")!
        let parsed = try StreamResolver.parse(
            "\u{feff}#EXTM3U\r\n#EXTINF:-1,Station\r\n../live\r\nhttps://other.example/audio\n../live\nfile:///tmp/audio",
            relativeTo: base
        )
        self.expect(
            parsed.map(\.absoluteString) == ["https://radio.example/live", "https://other.example/audio"],
            "M3U comments, BOM, relative links, duplicates and schemes"
        )

        let pls = try StreamResolver.parse(
            "[playlist]\nTitle1=Station\nFile2=https://second.example/live\nFile1=../first\nNumberOfEntries=2",
            relativeTo: base
        )
        self.expect(pls.map(\.absoluteString) == ["https://radio.example/first", "https://second.example/live"], "PLS numeric ordering")

        for invalid in ["#EXTM3U\n", "[playlist]\nFile1=file:///tmp/a", "<!DOCTYPE html><html>Radio</html>"] {
            do {
                _ = try StreamResolver.parse(invalid, relativeTo: base)
                preconditionFailure("Invalid playlist accepted")
            } catch is StreamResolver.ResolutionError {
                // Expected rejection.
            }
        }

        let redirected = URL(string: "https://cdn.example/playlists/list.m3u")!
        let resolved = try await StreamResolver.resolve(base) { url in
            if url == base {
                return .init(url: redirected, playlist: "#EXTM3U\nbroken.pls\nworking.pls")
            }
            if url.lastPathComponent == "broken.pls" {
                throw StreamResolver.ResolutionError.server(503)
            }
            if url.lastPathComponent == "working.pls" {
                return .init(url: url, playlist: "[playlist]\nFile1=../live")
            }
            return .init(url: url, playlist: nil)
        }
        self.expect(resolved.map(\.absoluteString) == ["https://cdn.example/live"], "Redirect base and failed-entry fallback")

        let hls = try await StreamResolver.resolve(base) { _ in
            return .init(url: redirected, playlist: "#EXTM3U\n#EXT-X-TARGETDURATION:6\nsegment.ts")
        }
        self.expect(hls == [redirected], "HLS must remain a manifest")

        do {
            _ = try await StreamResolver.resolve(base) { url in
                return .init(url: url, playlist: url.absoluteString)
            }
            preconditionFailure("Playlist loop accepted")
        } catch StreamResolver.ResolutionError.tooManyPlaylists {
            // Expected rejection.
        }

        var requests = 0
        do {
            _ = try await StreamResolver.resolve(base) { url in
                requests += 1
                return .init(url: url, playlist: "https://radio.example/\(requests).m3u")
            }
            preconditionFailure("Unbounded nesting accepted")
        } catch StreamResolver.ResolutionError.tooManyPlaylists {
            // Expected rejection.
        }
        self.expect(requests == 4, "Playlist depth must be bounded")

        let cancelled = Task {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try await StreamResolver.resolve(base) { url in
                return .init(url: url, playlist: nil)
            }
        }
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            preconditionFailure("Cancellation swallowed")
        } catch is CancellationError {
            // Expected cancellation.
        }

        let suite = "CusterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
        }

        let settings = Settings(store: Store(defaults: defaults))
        #if APP_STORE
        self.expect(settings.clickOpensMenu, "App Store must default to opening the menu")
        #else
        self.expect(!settings.clickOpensMenu, "GitHub must default to play/pause")
        #endif
        settings.clickOpensMenu = true
        self.expect(Settings(store: Store(defaults: defaults)).clickOpensMenu, "Menu choice persists")
        settings.clickOpensMenu = false
        self.expect(!Settings(store: Store(defaults: defaults)).clickOpensMenu, "Playback choice persists")

        if let address = CommandLine.arguments.dropFirst().first, let server = URL(string: address) {
            let urls = try await StreamResolver.resolve(server.appendingPathComponent("redirect.m3u"))
            self.expect(urls == [server.appendingPathComponent("live")], "HTTP redirect and nested playlists")

            let mime = try await StreamResolver.resolve(server.appendingPathComponent("playlist"))
            self.expect(mime == urls, "Playlist identified by MIME type")

            let manifest = try await StreamResolver.resolve(server.appendingPathComponent("hls.m3u8"))
            self.expect(manifest == [server.appendingPathComponent("hls.m3u8")], "HTTP HLS preserved")

            for path in ["webpage", "missing", "oversized.m3u", "oversized-chunked.m3u"] {
                do {
                    _ = try await StreamResolver.resolve(server.appendingPathComponent(path))
                    preconditionFailure("Invalid HTTP response accepted: \(path)")
                } catch is StreamResolver.ResolutionError {
                    // Expected rejection.
                }
            }
        }
        print("Playlist resolution, HTTP fixtures, and click preference tests passed")
    }
}
