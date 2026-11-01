import Foundation
import Combine
import MusicKit
import CryptoKit
import UIKit

@MainActor
final class AppleMusicAccount: ObservableObject {
    @Published private(set) var authorizationStatus = MusicAuthorization.currentStatus
    @Published private(set) var hasSubscription = false
    @Published private(set) var statusMessage = "Not connected"
    @Published var lastError: String?

    func connect() async {
        do {
            authorizationStatus = await MusicAuthorization.request()
            guard authorizationStatus == .authorized else {
                statusMessage = authorizationStatus == .denied ? "Permission denied" : "Not authorized"
                return
            }
            let subscription = try await MusicSubscription.current
            hasSubscription = subscription.canPlayCatalogContent
            statusMessage = hasSubscription ? "Connected · Apple Music" : "Connected · No active catalog subscription"
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Connection check failed"
        }
    }

    func search(_ term: String) async throws -> MusicCatalogSearchResponse {
        guard authorizationStatus == .authorized else { throw SonicError.unauthorized }
        var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self, Artist.self])
        request.limit = 25
        return try await request.response()
    }

    func play(_ song: Song) async throws {
        guard authorizationStatus == .authorized else { throw SonicError.unauthorized }
        let player = ApplicationMusicPlayer.shared
        player.queue = [song]
        try await player.play()
    }

    func pause() async { ApplicationMusicPlayer.shared.pause() }
}

@MainActor
final class SpotifyAccount: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var displayName: String?
    @Published private(set) var statusMessage = "Not connected"
    @Published private(set) var currentTrackName: String?
    @Published var lastError: String?

    private let redirectURI = "sonic://spotify-callback"
    private var verifier = ""
    private var oauthState = ""
    private var accessToken: String? { KeychainStore.get("spotify-access-token") }
    private var refreshToken: String? { KeychainStore.get("spotify-refresh-token") }

    init() {
        isConnected = accessToken != nil
        if isConnected {
            statusMessage = "Connected"
            Task { await loadProfile() }
        }
    }

    func authorizationURL(clientID: String) throws -> URL {
        guard !clientID.trimmingCharacters(in: .whitespaces).isEmpty else { throw AccountError.missingClientID }
        verifier = Self.randomString(length: 64)
        oauthState = Self.randomString(length: 24)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: oauthState),
            URLQueryItem(name: "scope", value: "user-read-private user-read-email user-library-read playlist-read-private user-read-currently-playing user-modify-playback-state")
        ]
        guard let url = components.url else { throw AccountError.invalidAuthorizationURL }
        try KeychainStore.set(clientID, for: "spotify-client-id")
        try KeychainStore.set(verifier, for: "spotify-pkce-verifier")
        try KeychainStore.set(oauthState, for: "spotify-oauth-state")
        statusMessage = "Waiting for Spotify authorization"
        return url
    }

    func handleCallback(_ url: URL) async {
        guard url.scheme == "sonic", url.host == "spotify-callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let error = values["error"] { lastError = "Spotify authorization: \(error)"; statusMessage = "Authorization cancelled"; return }
        guard let code = values["code"], values["state"] == KeychainStore.get("spotify-oauth-state"),
              let clientID = KeychainStore.get("spotify-client-id"),
              let savedVerifier = KeychainStore.get("spotify-pkce-verifier") else {
            lastError = "Spotify returned an invalid authorization response. Try connecting again."
            return
        }
        do {
            var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents()
            form.queryItems = [URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "grant_type", value: "authorization_code"), URLQueryItem(name: "code", value: code), URLQueryItem(name: "redirect_uri", value: redirectURI), URLQueryItem(name: "code_verifier", value: savedVerifier)]
            request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AccountError.spotifyTokenExchange }
            let token = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
            try KeychainStore.set(token.accessToken, for: "spotify-access-token")
            try KeychainStore.set(String(Date().timeIntervalSince1970 + Double(token.expiresIn)), for: "spotify-token-expiry")
            if let refresh = token.refreshToken { try KeychainStore.set(refresh, for: "spotify-refresh-token") }
            isConnected = true
            statusMessage = "Connected to Spotify"
            await loadProfile()
        } catch { lastError = error.localizedDescription; statusMessage = "Connection failed" }
    }

    func disconnect() {
        ["spotify-access-token", "spotify-refresh-token", "spotify-token-expiry", "spotify-client-id", "spotify-pkce-verifier", "spotify-oauth-state"].forEach { _ = KeychainStore.delete($0) }
        isConnected = false; displayName = nil; currentTrackName = nil; statusMessage = "Not connected"
    }

    func loadProfile() async {
        do {
            let data = try await spotifyRequest(path: "/v1/me")
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            displayName = json?["display_name"] as? String ?? json?["id"] as? String
            statusMessage = "Connected as \(displayName ?? "Spotify user")"
        } catch { lastError = error.localizedDescription }
    }

    func search(_ query: String) async throws -> Data {
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "track,album,artist"), URLQueryItem(name: "limit", value: "20")]
        guard let url = components.url else { throw AccountError.invalidAuthorizationURL }
        return try await spotifyRequest(url: url)
    }

    func searchTracks(_ query: String) async throws -> [SpotifyTrackSummary] {
        let data = try await search(query)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let trackContainer = root?["tracks"] as? [String: Any]
        let items = trackContainer?["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String, let title = item["name"] as? String,
                  let uri = item["uri"] as? String else { return nil }
            let artists = item["artists"] as? [[String: Any]] ?? []
            let artist = artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
            let album = item["album"] as? [String: Any]
            let images = album?["images"] as? [[String: Any]] ?? []
            let artwork = (images.first?["url"] as? String).flatMap { URL(string: $0) }
            return SpotifyTrackSummary(id: id, uri: uri, title: title, artist: artist, artworkURL: artwork)
        }
    }

    func play(uri: String) async throws {
        guard accessToken != nil else { throw SonicError.unauthorized }
        if let expiry = Double(KeychainStore.get("spotify-token-expiry") ?? ""), expiry < Date().timeIntervalSince1970 + 60 {
            try await refreshAccessToken()
        }
        guard let refreshedToken = accessToken else { throw SonicError.unauthorized }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/play")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["uris": [uri]])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AccountError.spotifyAPI((response as? HTTPURLResponse)?.statusCode ?? -1, "Spotify needs an active playback device and may require Premium for on-demand playback.")
        }
    }

    func playbackCommand(_ command: String) async throws {
        let methods: [String: String] = ["play": "PUT", "pause": "PUT", "next": "POST", "previous": "POST"]
        guard let method = methods[command] else { throw AccountError.invalidCommand }
        let suffix = command == "play" ? "play" : command == "pause" ? "pause" : command
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/\(suffix)")!)
        request.httpMethod = method
        _ = try await authorizedRequest(request)
    }

    private func spotifyRequest(path: String) async throws -> Data {
        try await spotifyRequest(url: URL(string: "https://api.spotify.com\(path)")!)
    }
    private func spotifyRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        return try await authorizedRequest(request)
    }
    private func authorizedRequest(_ originalRequest: URLRequest) async throws -> Data {
        if let expiry = Double(KeychainStore.get("spotify-token-expiry") ?? ""), expiry < Date().timeIntervalSince1970 + 60 {
            try await refreshAccessToken()
        }
        guard let token = accessToken else { throw SonicError.unauthorized }
        var request = originalRequest
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountError.network }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { isConnected = false }
            throw AccountError.spotifyAPI(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func refreshAccessToken() async throws {
        guard let refresh = refreshToken, let clientID = KeychainStore.get("spotify-client-id") else { throw SonicError.unauthorized }
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "grant_type", value: "refresh_token"), URLQueryItem(name: "refresh_token", value: refresh)]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AccountError.spotifyTokenExchange }
        let token = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        try KeychainStore.set(token.accessToken, for: "spotify-access-token")
        try KeychainStore.set(String(Date().timeIntervalSince1970 + Double(token.expiresIn)), for: "spotify-token-expiry")
        if let newRefresh = token.refreshToken { try KeychainStore.set(newRefresh, for: "spotify-refresh-token") }
        isConnected = true
    }

    private static func randomString(length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }
}

struct SpotifyTrackSummary: Identifiable {
    let id: String
    let uri: String
    let title: String
    let artist: String
    let artworkURL: URL?
}

private struct SpotifyTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in" }
}

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum AccountError: LocalizedError {
    case missingClientID, invalidAuthorizationURL, spotifyTokenExchange, invalidCommand, network
    case spotifyAPI(Int, String)
    var errorDescription: String? {
        switch self {
        case .missingClientID: return "Enter your Spotify Developer Client ID first."
        case .invalidAuthorizationURL: return "Could not create the authorization URL."
        case .spotifyTokenExchange: return "Spotify rejected the authorization code. Check your redirect URI and Client ID."
        case .invalidCommand: return "This Spotify playback command is not supported."
        case .network: return "Spotify did not return a valid response."
        case .spotifyAPI(let code, let detail): return "Spotify API error (\(code)): \(detail)"
        }
    }
}
