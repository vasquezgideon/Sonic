import Foundation

@main
struct ModelSmoke {
    static func main() {
        precondition(PlaybackRate.clamped(0.1) == 0.5)
        precondition(PlaybackRate.clamped(3.0) == 2.0)
        precondition(PlaybackRate.clamped(.nan) == 1.0)
        precondition(PlaybackRate.clamped(.infinity) == 1.0)

        let url = URL(string: "https://example.com/audio.flac")!
        func makeTrack(_ bitrate: Int?) -> Track {
            Track(id: "smoke", title: "Smoke", artist: "Sonic", album: "Tests", artworkURL: nil,
                  streamURL: url, downloadURL: nil, duration: nil, sourceID: "test", sourceName: "Test",
                  isDownloadable: false, localFileName: nil, format: "FLAC", bitrate: bitrate)
        }
        precondition(makeTrack(320_000).bitrateLabel == "320 kbps")
        precondition(makeTrack(320).bitrateLabel == "320 kbps")
        precondition(makeTrack(nil).bitrateLabel == nil)

        let archiveJSON = #"{"files":[{"name":"track.flac","format":"FLAC","size":"12345","source":"original","private":false}]}"#.data(using: .utf8)!
        let archive = try! JSONDecoder().decode(ArchiveMetadata.self, from: archiveJSON)
        precondition(archive.files.first?.size == "12345")
        precondition(archive.files.first?.source == "original")
        precondition(archive.files.first?.privateFile == false)
        print("Playback rate, bitrate and archive metadata smoke tests: OK")
    }
}
