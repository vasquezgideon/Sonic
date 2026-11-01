import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: TimeInterval
    let text: String
}

struct LyricsResult {
    let plainText: String?
    let lines: [LyricLine]
    var isSynced: Bool { !lines.isEmpty }
}

/// Uses LRCLIB's public lookup API. Lyrics are best-effort and are never required for playback.
final class LyricsService {
    func fetch(for track: Track) async throws -> LyricsResult? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album)
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Sonic iOS/1.3", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LyricsError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else { throw LyricsError.httpStatus(http.statusCode) }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let synced = Self.parseSynced(payload.syncedLyrics ?? "")
        guard payload.plainLyrics != nil || !synced.isEmpty else { return nil }
        return LyricsResult(plainText: payload.plainLyrics, lines: synced)
    }

    static func parseSynced(_ source: String) -> [LyricLine] {
        let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\](.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [LyricLine] = []
        for (index, rawLine) in source.components(separatedBy: .newlines).enumerated() {
            let line = rawLine as NSString
            let range = NSRange(location: 0, length: line.length)
            guard let match = regex.firstMatch(in: rawLine, range: range), match.numberOfRanges >= 5,
                  let minutes = Int(line.substring(with: match.range(at: 1))),
                  let seconds = Int(line.substring(with: match.range(at: 2))) else { continue }
            let fractionText = match.range(at: 3).location == NSNotFound ? "0" : line.substring(with: match.range(at: 3))
            let fraction = Double("0." + fractionText) ?? 0
            let text = line.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
            result.append(LyricLine(id: index, time: Double(minutes * 60 + seconds) + fraction, text: text))
        }
        return result.sorted { $0.time < $1.time }
    }

    private struct Payload: Decodable {
        let plainLyrics: String?
        let syncedLyrics: String?
        enum CodingKeys: String, CodingKey { case plainLyrics, syncedLyrics }
    }
}

enum LyricsError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The lyrics service returned an invalid response."
        case .httpStatus(let status): return "Lyrics lookup failed (HTTP \(status))."
        }
    }
}
