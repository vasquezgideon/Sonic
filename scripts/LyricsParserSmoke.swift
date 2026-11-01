import Foundation

struct Track {
    let title: String
    let artist: String
    let album: String
}

@main
struct LyricsParserSmoke {
    static func main() {
        let source = "[00:02.50]Second line\n[00:01.00]First line\n[abc]bad"
        let lines = LyricsService.parseSynced(source)
        precondition(lines.count == 2, "Expected two valid lyric lines")
        precondition(lines[0].text == "First line" && abs(lines[0].time - 1.0) < 0.001)
        precondition(lines[1].text == "Second line" && abs(lines[1].time - 2.5) < 0.001)
        print("Lyrics parser smoke test: OK")
    }
}
