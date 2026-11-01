import Foundation

struct Track: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var artworkURL: URL?
    var streamURL: URL
    var downloadURL: URL?
    var duration: TimeInterval?
    var sourceID: String
    var sourceName: String
    var isDownloadable: Bool
    var localFileName: String?
    var format: String?
    var bitrate: Int?

    var isLocal: Bool { localFileName != nil }

    /// Provider APIs disagree: Subsonic commonly reports kbps, while Jellyfin reports bits/second.
    var bitrateLabel: String? {
        guard let bitrate, bitrate > 0 else { return nil }
        let kbps = bitrate > 10_000 ? Double(bitrate) / 1_000 : Double(bitrate)
        return "\(Int(kbps.rounded())) kbps"
    }

    static func local(url: URL) -> Track {
        Track(id: UUID().uuidString, title: url.deletingPathExtension().lastPathComponent,
              artist: "Local file", album: "Imported", artworkURL: nil, streamURL: url,
              downloadURL: nil, duration: nil, sourceID: "local", sourceName: "On this iPhone",
              isDownloadable: false, localFileName: nil, format: url.pathExtension.uppercased(), bitrate: nil)
    }
}

enum PlaybackRate {
    static let minimum = 0.5
    static let maximum = 2.0
    static let presets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(maximum, max(minimum, value))
    }
}

struct MusicSource: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case internetArchive = "Internet Archive"
        case audius = "Audius"
        case subsonic = "Subsonic / Navidrome"
        case jellyfin = "Jellyfin"
        case direct = "Direct stream"
        var id: String { rawValue }
    }
    var id: String = UUID().uuidString
    var name: String
    var kind: Kind
    var baseURL: URL?
    var username: String = ""
    var password: String = ""
    var apiKey: String = ""
    var userID: String = ""

    init(id: String = UUID().uuidString, name: String, kind: Kind, baseURL: URL? = nil,
         username: String = "", password: String = "", apiKey: String = "", userID: String = "") {
        self.id = id; self.name = name; self.kind = kind; self.baseURL = baseURL
        self.username = username; self.password = password; self.apiKey = apiKey; self.userID = userID
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, baseURL, username, userID }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind); baseURL = try c.decodeIfPresent(URL.self, forKey: .baseURL)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? ""
        password = KeychainStore.get("password-\(id)") ?? ""
        apiKey = KeychainStore.get("apikey-\(id)") ?? ""
    }
    func encode(to encoder: Encoder) throws {
        try KeychainStore.set(password, for: "password-\(id)")
        try KeychainStore.set(apiKey, for: "apikey-\(id)")
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(baseURL, forKey: .baseURL); try c.encode(username, forKey: .username); try c.encode(userID, forKey: .userID)
    }
}
