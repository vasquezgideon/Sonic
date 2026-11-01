import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CryptoKit

final class ServerService {
    func search(_ query: String, on source: MusicSource) async throws -> [Track] {
        switch source.kind {
        case .internetArchive: return try await CatalogService().searchInternetArchive(query)
        case .audius: return try await searchAudius(query)
        case .subsonic: return try await searchSubsonic(query, source: source)
        case .jellyfin: return try await searchJellyfin(query, source: source)
        case .direct: return try directSearch(query, source: source)
        }
    }


    private func searchAudius(_ query: String) async throws -> [Track] {
        var components = URLComponents(string: "https://api.audius.co/v1/tracks/search")!
        components.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "app_name", value: "Sonic"), URLQueryItem(name: "limit", value: "40")]
        let data = try await request(components.url!)
        let response = try JSONDecoder().decode(AudiusResponse.self, from: data)
        return response.data.map { item in
            let stream = URL(string: "https://api.audius.co/v1/tracks/\(item.id)/stream?app_name=Sonic")!
            let download = item.isDownloadable == true ? URL(string: "https://api.audius.co/v1/tracks/\(item.id)/download?app_name=Sonic") : nil
            let artwork = item.artwork?.medium480.flatMap(URL.init(string:)) ?? item.artwork?.large.flatMap(URL.init(string:)) ?? item.artwork?.medium150.flatMap(URL.init(string:)) ?? item.artwork?.small.flatMap(URL.init(string:))
            return Track(id: "aud-\(item.id)", title: item.title, artist: item.user?.name ?? "Audius artist", album: item.genre ?? "Audius",
                         artworkURL: artwork, streamURL: stream, downloadURL: download, duration: item.duration.map(TimeInterval.init),
                         sourceID: "audius", sourceName: "Audius", isDownloadable: item.isDownloadable == true,
                         localFileName: nil, format: "STREAM", bitrate: nil)
        }
    }

    private func searchSubsonic(_ query: String, source: MusicSource) async throws -> [Track] {
        guard let base = source.baseURL else { throw SonicError.invalidServer }
        let auth = subsonicAuth(source)
        var components = URLComponents(url: base.appendingPathComponent("rest/search3.view"), resolvingAgainstBaseURL: false)!
        components.queryItems = auth + [URLQueryItem(name: "query", value: query), URLQueryItem(name: "songCount", value: "60"), URLQueryItem(name: "albumCount", value: "0"), URLQueryItem(name: "artistCount", value: "0")]
        let data = try await request(components.url!)
        let envelope = try JSONDecoder().decode(SubsonicEnvelope.self, from: data)
        guard envelope.subsonicResponse.status == "ok" else { throw SonicError.invalidServer }
        return (envelope.subsonicResponse.searchResult3?.song ?? []).compactMap { song in
            guard let stream = endpoint(base, "rest/stream.view", auth + [URLQueryItem(name: "id", value: song.id)]) else { return nil }
            let cover = song.coverArt.flatMap { endpoint(base, "rest/getCoverArt.view", auth + [URLQueryItem(name: "id", value: $0), URLQueryItem(name: "size", value: "640")]) }
            let download = endpoint(base, "rest/download.view", auth + [URLQueryItem(name: "id", value: song.id)])
            return Track(id: "sub-\(song.id)", title: song.title, artist: song.artist ?? "Unknown artist", album: song.album ?? "", artworkURL: cover,
                         streamURL: stream, downloadURL: download, duration: song.duration.map(TimeInterval.init), sourceID: source.id, sourceName: source.name,
                         isDownloadable: true, localFileName: nil, format: song.suffix?.uppercased(), bitrate: song.bitRate)
        }
    }

    private func searchJellyfin(_ query: String, source: MusicSource) async throws -> [Track] {
        guard let base = source.baseURL, !source.userID.isEmpty else { throw SonicError.invalidServer }
        var components = URLComponents(url: base.appendingPathComponent("Items"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "searchTerm", value: query), URLQueryItem(name: "IncludeItemTypes", value: "Audio"), URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "Limit", value: "60"), URLQueryItem(name: "Fields", value: "MediaSources,Path")]
        var request = URLRequest(url: components.url!)
        request.setValue(source.apiKey, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("MediaBrowser Token=\(source.apiKey)", forHTTPHeaderField: "X-Emby-Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SonicError.unauthorized }
        let result = try JSONDecoder().decode(JellyfinItems.self, from: data)
        return result.items.map { item in
            var streamComponents = URLComponents(url: base.appendingPathComponent("Audio/\(item.id)/universal"), resolvingAgainstBaseURL: false)!
            streamComponents.queryItems = [URLQueryItem(name: "UserId", value: source.userID), URLQueryItem(name: "api_key", value: source.apiKey), URLQueryItem(name: "Container", value: "flac,mp3,m4a,aac,wav,ogg")]
            let artwork = URL(string: "Items/\(item.id)/Images/Primary?maxWidth=640&api_key=\(source.apiKey)", relativeTo: base)
            let download = URL(string: "Items/\(item.id)/Download?api_key=\(source.apiKey)", relativeTo: base)
            return Track(id: "jf-\(item.id)", title: item.name, artist: item.artists?.first ?? item.albumArtist ?? "Unknown artist", album: item.album ?? "", artworkURL: artwork,
                         streamURL: streamComponents.url!, downloadURL: download, duration: item.runTimeTicks.map { Double($0) / 10_000_000 },
                         sourceID: source.id, sourceName: source.name, isDownloadable: true, localFileName: nil, format: item.mediaSources?.first?.container?.uppercased(), bitrate: item.mediaSources?.first?.bitrate)
        }
    }

    private func directSearch(_ query: String, source: MusicSource) throws -> [Track] {
        guard let url = URL(string: query), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw SonicError.invalidServer }
        let name = url.lastPathComponent.isEmpty ? "Direct stream" : url.deletingPathExtension().lastPathComponent
        return [Track(id: UUID().uuidString, title: name, artist: "Direct URL", album: source.name, artworkURL: nil, streamURL: url, downloadURL: url,
                      duration: nil, sourceID: source.id, sourceName: source.name, isDownloadable: true, localFileName: nil, format: url.pathExtension.uppercased(), bitrate: nil)]
    }

    private func request(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw SonicError.invalidServer }
        return data
    }

    private func endpoint(_ base: URL, _ path: String, _ items: [URLQueryItem]) -> URL? {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        c?.queryItems = items
        return c?.url
    }

    private func subsonicAuth(_ source: MusicSource) -> [URLQueryItem] {
        let salt = String(UUID().uuidString.prefix(8))
        let digest = Insecure.MD5.hash(data: Data((source.password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        return [URLQueryItem(name: "u", value: source.username), URLQueryItem(name: "t", value: digest), URLQueryItem(name: "s", value: salt),
                URLQueryItem(name: "v", value: "1.16.1"), URLQueryItem(name: "c", value: "Sonic iOS"), URLQueryItem(name: "f", value: "json")]
    }
}

private struct SubsonicEnvelope: Decodable { let subsonicResponse: SubsonicResponse; enum CodingKeys: String, CodingKey { case subsonicResponse = "subsonic-response" } }
private struct SubsonicResponse: Decodable { let status: String; let searchResult3: SearchResult? }
private struct SearchResult: Decodable { let song: [SubsonicSong]? }
private struct SubsonicSong: Decodable { let id: String; let title: String; let artist: String?; let album: String?; let coverArt: String?; let duration: Int?; let suffix: String?; let bitRate: Int? }
private struct JellyfinItems: Decodable {
    let items: [JellyfinItem]
    enum CodingKeys: String, CodingKey { case items = "Items" }
}
private struct JellyfinItem: Decodable {
    let id: String; let name: String; let artists: [String]?; let albumArtist: String?; let album: String?; let runTimeTicks: Int64?; let mediaSources: [JellyfinMediaSource]?
    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", artists = "Artists", albumArtist = "AlbumArtist", album = "Album", runTimeTicks = "RunTimeTicks", mediaSources = "MediaSources"
    }
}
private struct JellyfinMediaSource: Decodable {
    let container: String?; let bitrate: Int?
    enum CodingKeys: String, CodingKey { case container = "Container", bitrate = "Bitrate" }
}

private struct AudiusResponse: Decodable { let data: [AudiusTrack] }
private struct AudiusTrack: Decodable {
    let id: String; let title: String; let duration: Int?; let genre: String?; let isDownloadable: Bool?
    let user: AudiusUser?; let artwork: AudiusArtwork?
    enum CodingKeys: String, CodingKey { case id, title, duration, genre, user, artwork, isDownloadable = "is_downloadable" }
}
private struct AudiusUser: Decodable { let name: String? }
private struct AudiusArtwork: Decodable {
    let large: String?; let small: String?; let medium150: String?; let medium480: String?
    enum CodingKeys: String, CodingKey { case large, small, medium150 = "150x150", medium480 = "480x480" }
}
