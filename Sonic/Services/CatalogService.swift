import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Internet Archive provides a searchable catalog of recordings and files whose
/// individual item licenses/rights vary. The app only exposes direct files when
/// the item's metadata marks them as downloadable.
struct ArchiveDocument: Decodable {
    let response: Response
    struct Response: Decodable { let docs: [Document] }
    struct Document: Decodable {
        let identifier: String
        let title: String?
        let creator: String?
        let year: String?
    }
}

struct ArchiveMetadata: Decodable {
    let files: [File]
    struct File: Decodable {
        let name: String
        let format: String?
        let size: String?
        let source: String?
        let privateFile: Bool?
        enum CodingKeys: String, CodingKey { case name, format, size, source, privateFile = "private" }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            format = try container.decodeIfPresent(String.self, forKey: .format)
            size = try container.decodeIfPresent(String.self, forKey: .size)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            if let boolValue = try? container.decode(Bool.self, forKey: .privateFile) {
                privateFile = boolValue
            } else if let stringValue = try? container.decode(String.self, forKey: .privateFile) {
                privateFile = stringValue.lowercased() == "true"
            } else {
                privateFile = nil
            }
        }
    }
}

final class CatalogService {
    func searchInternetArchive(_ query: String) async throws -> [Track] {
        var components = URLComponents(string: "https://archive.org/advancedsearch.php")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "(mediatype:audio) AND (\(query))"),
            URLQueryItem(name: "fl[]", value: "identifier,title,creator,year"),
            URLQueryItem(name: "rows", value: "40"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "output", value: "json")
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let results = try JSONDecoder().decode(ArchiveDocument.self, from: data)
        return try await withThrowingTaskGroup(of: Track?.self) { group in
            for doc in results.response.docs.prefix(25) {
                group.addTask { try await self.track(for: doc) }
            }
            var tracks: [Track] = []
            for try await item in group { if let item { tracks.append(item) } }
            return tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    private func track(for doc: ArchiveDocument.Document) async throws -> Track? {
        let metadataURL = URL(string: "https://archive.org/metadata/\(doc.identifier)")!
        let (data, _) = try await URLSession.shared.data(from: metadataURL)
        let metadata = try JSONDecoder().decode(ArchiveMetadata.self, from: data)
        let candidates = metadata.files.filter { file in
            guard file.privateFile != true, let format = file.format?.lowercased() else { return false }
            return ["mp3", "flac", "ogg", "wave", "wav", "aiff", "aac", "m4a"].contains(where: { format.contains($0) })
                && !file.name.hasSuffix("_spectrogram.png") && !file.name.hasSuffix(".xml")
        }
        guard let file = candidates.first(where: { ($0.format ?? "").localizedCaseInsensitiveContains("flac") }) ?? candidates.first else { return nil }
        let encodedName = file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.name
        guard let stream = URL(string: "https://archive.org/download/\(doc.identifier)/\(encodedName)") else { return nil }
        let format = file.format ?? URL(fileURLWithPath: file.name).pathExtension
        let artwork = URL(string: "https://archive.org/services/img/\(doc.identifier)")
        return Track(id: "ia-\(doc.identifier)-\(file.name)", title: URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent == "" ? (doc.title ?? file.name) : (doc.title ?? URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent),
                     artist: doc.creator ?? "Unknown artist", album: doc.year ?? "Internet Archive", artworkURL: artwork,
                     streamURL: stream, downloadURL: stream, duration: nil, sourceID: "internet-archive", sourceName: "Internet Archive",
                     isDownloadable: true, localFileName: nil, format: format, bitrate: nil)
    }
}
