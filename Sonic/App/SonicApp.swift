import SwiftUI

@main
struct SonicApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var playback = PlaybackManager()
    @StateObject private var appleMusic = AppleMusicAccount()
    @StateObject private var spotify = SpotifyAccount()
    @AppStorage("sonic.theme") private var theme = "dark"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(playback)
                .environmentObject(appleMusic)
                .environmentObject(spotify)
                .preferredColorScheme(theme == "system" ? nil : (theme == "light" ? .light : .dark))
                .tint(Color(red: 0.36, green: 0.72, blue: 1.0))
        }
    }
}
