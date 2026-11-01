import Foundation
import Combine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class LibraryStore: ObservableObject {
    @Published var favorites: [Track] = []
    @Published var downloads: [Track] = []
    @Published var recentlyPlayed: [Track] = []
    @Published var sources: [MusicSource] = [MusicSource(name: "Internet Archive", kind: .internetArchive), MusicSource(name: "Audius", kind: .audius)]
    @Published var playlists: [String: [Track]] = [:]
    @Published var playlistFolders: [String: String] = [:]

    private let directory: URL
    private let metadataURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("SonicDownloads", isDirectory: true)
        metadataURL = docs.appendingPathComponent("sonic-library.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func toggleFavorite(_ track: Track) {
        if favorites.contains(where: { $0.id == track.id }) { favorites.removeAll { $0.id == track.id } }
        else { favorites.insert(track, at: 0) }
        save()
    }

    func isFavorite(_ track: Track) -> Bool { favorites.contains { $0.id == track.id } }

    func recordPlay(_ track: Track) {
        recentlyPlayed.removeAll { $0.id == track.id }
        recentlyPlayed.insert(track, at: 0)
        recentlyPlayed = Array(recentlyPlayed.prefix(40))
        save()
    }

    func downloadedURL(for track: Track) -> URL? {
        guard let name = track.localFileName else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ track: Track) async throws {
        guard track.isDownloadable else { throw SonicError.notDownloadable }
        if downloads.contains(where: { $0.id == track.id && downloadedURL(for: $0) != nil }) { return }
        let url = track.downloadURL ?? track.streamURL
        let (temporary, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw SonicError.invalidServer }
        let ext = url.pathExtension.isEmpty ? (track.format?.lowercased() ?? "audio") : url.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(filename)
        try FileManager.default.moveItem(at: temporary, to: destination)
        var saved = track
        saved.localFileName = filename
        saved.streamURL = destination
        if !downloads.contains(where: { $0.id == saved.id }) { downloads.insert(saved, at: 0) }
        save()
    }

    func importLocalFile(_ url: URL) throws -> Track {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: url, to: destination)
        var track = Track.local(url: destination)
        track.localFileName = filename
        track.streamURL = destination
        track.sourceName = "On this iPhone"
        downloads.insert(track, at: 0)
        save()
        return track
    }

    func removeDownload(_ track: Track) {
        if let url = downloadedURL(for: track) { try? FileManager.default.removeItem(at: url) }
        downloads.removeAll { $0.id == track.id }
        save()
    }

    func addSource(_ source: MusicSource) { sources.append(source); save() }

    @discardableResult
    func createPlaylist(name rawName: String, folder rawFolder: String = "") -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, playlists[name] == nil else { return false }
        let folder = rawFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists[name] = []
        if !folder.isEmpty { playlistFolders[name] = folder }
        save()
        return true
    }

    func addToPlaylist(_ track: Track, named name: String) {
        guard playlists[name] != nil else { return }
        if playlists[name]?.contains(where: { $0.id == track.id }) != true {
            playlists[name, default: []].append(track)
            save()
        }
    }

    func removeFromPlaylist(_ track: Track, named name: String) {
        playlists[name]?.removeAll { $0.id == track.id }
        save()
    }

    func deletePlaylist(named name: String) {
        playlists.removeValue(forKey: name)
        playlistFolders.removeValue(forKey: name)
        save()
    }

    private struct Snapshot: Codable {
        var favorites: [Track]
        var downloads: [Track]
        var recentlyPlayed: [Track]
        var sources: [MusicSource]
        var playlists: [String: [Track]]
        var playlistFolders: [String: String]

        private enum CodingKeys: String, CodingKey { case favorites, downloads, recentlyPlayed, sources, playlists, playlistFolders }
        init(favorites: [Track], downloads: [Track], recentlyPlayed: [Track], sources: [MusicSource], playlists: [String: [Track]], playlistFolders: [String: String]) {
            self.favorites = favorites; self.downloads = downloads; self.recentlyPlayed = recentlyPlayed
            self.sources = sources; self.playlists = playlists; self.playlistFolders = playlistFolders
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            favorites = try c.decode([Track].self, forKey: .favorites)
            downloads = try c.decode([Track].self, forKey: .downloads)
            recentlyPlayed = try c.decode([Track].self, forKey: .recentlyPlayed)
            sources = try c.decode([MusicSource].self, forKey: .sources)
            playlists = try c.decode([String: [Track]].self, forKey: .playlists)
            playlistFolders = try c.decodeIfPresent([String: String].self, forKey: .playlistFolders) ?? [:]
        }
    }

    private func save() {
        let snapshot = Snapshot(favorites: favorites, downloads: downloads, recentlyPlayed: recentlyPlayed, sources: sources, playlists: playlists, playlistFolders: playlistFolders)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: metadataURL, options: .atomic) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: metadataURL), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        favorites = snapshot.favorites.map(rehydrateLocalURL)
        recentlyPlayed = snapshot.recentlyPlayed.map(rehydrateLocalURL)
        downloads = snapshot.downloads.compactMap { saved in
            let track = rehydrateLocalURL(saved)
            return downloadedURL(for: track) == nil ? nil : track
        }
        if !snapshot.sources.isEmpty { sources = snapshot.sources }
        playlists = snapshot.playlists.mapValues { $0.map(rehydrateLocalURL) }
        playlistFolders = snapshot.playlistFolders
    }

    private func rehydrateLocalURL(_ saved: Track) -> Track {
        var track = saved
        if let filename = track.localFileName {
            track.streamURL = directory.appendingPathComponent(filename)
        }
        return track
    }
}

enum SonicError: LocalizedError {
    case notDownloadable, invalidServer, unauthorized, noResults, unsupported
    var errorDescription: String? {
        switch self {
        case .notDownloadable: return "This provider does not allow downloading this track."
        case .invalidServer: return "The server address or response was invalid."
        case .unauthorized: return "The server rejected the credentials."
        case .noResults: return "No playable audio files were found."
        case .unsupported: return "This source or audio format is not supported by the current playback engine."
        }
    }
}
