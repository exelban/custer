//
//  StreamResolver.swift
//  Custer
//
//  Created by Serhiy Mytrovtsiy on 26/09/2026.
//  Using Swift 6.0.
//  Running on macOS 27.0.
//
//  Copyright © 2026 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation

/// Resolves radio playlists, leaving HLS manifests to AVFoundation.
internal enum StreamResolver {
    struct Resource {
        let url: URL
        /// Nil means a direct media response; its body is never downloaded here.
        let playlist: String?
    }
    
    enum ResolutionError: LocalizedError {
        case invalidAddress
        case webpage
        case emptyPlaylist
        case tooLarge
        case tooManyPlaylists
        case server(Int)
        
        var errorDescription: String? {
            switch self {
            case .invalidAddress:
                return "Use an HTTP or HTTPS stream or playlist address"
            case .webpage:
                return "This address is a webpage. Use the station’s direct stream or M3U/PLS playlist link"
            case .emptyPlaylist:
                return "The playlist contains no supported HTTP or HTTPS streams"
            case .tooLarge:
                return "The playlist is too large"
            case .tooManyPlaylists:
                return "The playlist contains too many nested or repeated playlists"
            case .server(let status):
                return "The stream server returned HTTP \(status)"
            }
        }
    }
    
    static func isSupported(_ url: URL) -> Bool {
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }
    
    static func resolve(_ url: URL, fetch: (URL) async throws -> Resource = StreamResolver.fetchResource) async throws -> [URL] {
        var visited = Set<URL>()
        var remaining = 10
        return try await self.expand(url, depth: 0, visited: &visited, remaining: &remaining, fetch: fetch)
    }
    
    private static func expand(_ url: URL, depth: Int, visited: inout Set<URL>, remaining: inout Int,
                               fetch: (URL) async throws -> Resource) async throws -> [URL] {
        try Task.checkCancellation()

        guard self.isSupported(url) else {
            throw ResolutionError.invalidAddress
        }
        guard depth <= 3, remaining > 0, visited.insert(url).inserted else {
            throw ResolutionError.tooManyPlaylists
        }

        remaining -= 1
        let resource = try await fetch(url)
        guard let text = resource.playlist else {
            return [resource.url]
        }

        // Extended M3U radio lists also start with EXTM3U. Only EXT-X tags identify HLS.
        if text.components(separatedBy: .newlines).contains(where: {
            $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("#EXT-X-")
        }) {
            return [resource.url]
        }

        let entries = try self.parse(text, relativeTo: resource.url)
        var results: [URL] = []
        var lastError: Error = ResolutionError.emptyPlaylist

        for entry in entries.prefix(5) {
            do {
                let urls = try await self.expand(entry, depth: depth + 1, visited: &visited,
                                                 remaining: &remaining, fetch: fetch)
                for url in urls where !results.contains(url) {
                    results.append(url)
                }
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }

        guard !results.isEmpty else {
            throw lastError
        }
        return Array(results.prefix(5))
    }
    
    static func parse(_ text: String, relativeTo base: URL) throws -> [URL] {
        let text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        let lower = text.lowercased()
        guard !lower.hasPrefix("<!doctype html"), !lower.hasPrefix("<html") else {
            throw ResolutionError.webpage
        }

        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let isPLS = lines.contains { $0.lowercased() == "[playlist]" }
        let addresses: [String]
        if isPLS {
            addresses = lines
                .compactMap { line -> (Int, String)? in
                    let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2 else {
                        return nil
                    }

                    let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                    guard key.hasPrefix("file"), let index = Int(key.dropFirst(4)), index > 0 else {
                        return nil
                    }
                    return (index, parts[1].trimmingCharacters(in: .whitespaces))
                }
                .sorted { $0.0 < $1.0 }
                .map { $0.1 }
        } else {
            addresses = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }

        var urls: [URL] = []
        for address in addresses where !address.isEmpty {
            guard let url = URL(string: address, relativeTo: base)?.absoluteURL, self.isSupported(url) else {
                continue
            }
            if !urls.contains(url) {
                urls.append(url)
            }
        }

        guard !urls.isEmpty else {
            throw ResolutionError.emptyPlaylist
        }
        return urls
    }
    
    static func fetchResource(_ url: URL) async throws -> Resource {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15

        let session = URLSession(configuration: configuration)
        // Also cancels direct radio responses without consuming an endless audio body.
        defer {
            session.invalidateAndCancel()
        }

        let (bytes, response) = try await session.bytes(from: url)
        try Task.checkCancellation()

        guard let response = response as? HTTPURLResponse else {
            throw ResolutionError.invalidAddress
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ResolutionError.server(response.statusCode)
        }

        let finalURL = response.url ?? url
        guard self.isSupported(finalURL) else {
            throw ResolutionError.invalidAddress
        }

        let mime = response.mimeType?.lowercased() ?? ""
        guard mime != "text/html", mime != "application/xhtml+xml" else {
            throw ResolutionError.webpage
        }

        let playlistTypes = [
            "audio/x-mpegurl",
            "audio/mpegurl",
            "application/x-mpegurl",
            "application/vnd.apple.mpegurl",
            "audio/x-scpls",
            "application/pls+xml"
        ]
        let isPlaylist = ["m3u", "m3u8", "pls"].contains(finalURL.pathExtension.lowercased())
            || ["m3u", "m3u8", "pls"].contains(url.pathExtension.lowercased())
            || playlistTypes.contains(mime)
        guard isPlaylist else {
            return Resource(url: finalURL, playlist: nil)
        }

        let limit = 256 * 1024
        guard response.expectedContentLength <= limit else {
            throw ResolutionError.tooLarge
        }

        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else {
                throw ResolutionError.tooLarge
            }
            data.append(byte)
        }

        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ResolutionError.emptyPlaylist
        }
        return Resource(url: finalURL, playlist: text)
    }
}
