import XCTest
@testable import Sonic

final class LyricsParserTests: XCTestCase {
    func testParsesAndSortsSyncedLines() {
        let source = "[00:02.50]Second line\n[00:01.00]First line\nnot a lyric timestamp"
        let lines = LyricsService.parseSynced(source)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "First line")
        XCTAssertEqual(lines[0].time, 1.0, accuracy: 0.001)
        XCTAssertEqual(lines[1].text, "Second line")
        XCTAssertEqual(lines[1].time, 2.5, accuracy: 0.001)
    }

    func testParsesMillisecondsAndEmptyLine() {
        let lines = LyricsService.parseSynced("[01:02.125]Hello\n[01:03.00]")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].time, 62.125, accuracy: 0.001)
        XCTAssertEqual(lines[1].text, "")
    }

    func testIgnoresMalformedTimestamps() {
        XCTAssertTrue(LyricsService.parseSynced("[abc]Nope\n[1:xx]Nope").isEmpty)
    }
}


final class PlaybackRateTests: XCTestCase {
    func testPlaybackRateClampsToSupportedRange() {
        XCTAssertEqual(PlaybackRate.clamped(0.1), 0.5)
        XCTAssertEqual(PlaybackRate.clamped(3.0), 2.0)
        XCTAssertEqual(PlaybackRate.clamped(1.25), 1.25)
    }

    func testInvalidPlaybackRateFallsBackToNormalSpeed() {
        XCTAssertEqual(PlaybackRate.clamped(.nan), 1.0)
        XCTAssertEqual(PlaybackRate.clamped(.infinity), 1.0)
    }
}

final class BitrateLabelTests: XCTestCase {
    private func track(bitrate: Int?) -> Track {
        Track(id: "test", title: "Test", artist: "Artist", album: "Album", artworkURL: nil,
              streamURL: URL(string: "https://example.com/test.flac")!, downloadURL: nil,
              duration: nil, sourceID: "test", sourceName: "Test", isDownloadable: false,
              localFileName: nil, format: "FLAC", bitrate: bitrate)
    }

    func testBitrateNormalizesBitsPerSecondAndKilobitsPerSecond() {
        XCTAssertEqual(track(bitrate: 320_000).bitrateLabel, "320 kbps")
        XCTAssertEqual(track(bitrate: 320).bitrateLabel, "320 kbps")
    }

    func testMissingBitrateHasNoClaim() {
        XCTAssertNil(track(bitrate: nil).bitrateLabel)
    }
}


final class ArchiveMetadataTests: XCTestCase {
    func testOptionalArchiveFieldsDecodeAlongsidePrivateFlag() throws {
        let json = #"{"files":[{"name":"song.flac","format":"FLAC","size":"12345","source":"original","private":false}]}"#.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(ArchiveMetadata.self, from: json)
        XCTAssertEqual(metadata.files.first?.size, "12345")
        XCTAssertEqual(metadata.files.first?.source, "original")
        XCTAssertEqual(metadata.files.first?.privateFile, false)
    }

    func testStringPrivateFlagIsAccepted() throws {
        let json = #"{"files":[{"name":"song.mp3","format":"MP3","private":"true"}]}"#.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(ArchiveMetadata.self, from: json)
        XCTAssertEqual(metadata.files.first?.privateFile, true)
    }
}
