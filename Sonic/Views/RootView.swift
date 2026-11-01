import SwiftUI
import UniformTypeIdentifiers
import MusicKit

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var spotify: SpotifyAccount
    @State private var selectedTab = 0
    @State private var showPlayer = false
    @State private var showImporter = false
    @State private var alertMessage: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                HomeView(showPlayer: $showPlayer).tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
                SearchView(showPlayer: $showPlayer).tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(1)
                LibraryView(showPlayer: $showPlayer, showImporter: $showImporter).tabItem { Label("Your Library", systemImage: "books.vertical") }.tag(2)
                SourcesView().tabItem { Label("Sources", systemImage: "server.rack") }.tag(3)
                SettingsView().tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(4)
            }
            .toolbarBackground(.ultraThinMaterial, for: .tabBar)
            if playback.currentTrack != nil {
                MiniPlayer(showPlayer: $showPlayer).padding(.horizontal, 12).padding(.bottom, 54)
            }
        }
        .sheet(isPresented: $showPlayer) { NowPlayingView().environmentObject(playback).presentationDetents([.large]) }
        .onOpenURL { url in Task { await spotify.handleCallback(url) } }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff], allowsMultipleSelection: true) { result in
            do { for url in try result.get() { _ = try library.importLocalFile(url) } }
            catch { alertMessage = error.localizedDescription }
        }
        .alert("Sonic", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: { Text(alertMessage ?? "") }
    }
}

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @Binding var showPlayer: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Good music. Your rules.").font(.subheadline).foregroundStyle(.secondary)
                            Text("Sonic").font(.system(size: 36, weight: .bold, design: .rounded))
                        }
                        Spacer()
                        Image(systemName: "waveform") .font(.system(size: 25, weight: .semibold)).foregroundStyle(.cyan)
                            .padding(14).background(.ultraThinMaterial, in: Circle())
                    }
                    if !library.recentlyPlayed.isEmpty {
                        sectionTitle("Jump back in")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(library.recentlyPlayed.prefix(4)) { track in
                                Button { playback.play(track, queue: library.recentlyPlayed); showPlayer = true } label: {
                                    HStack(spacing: 9) {
                                        ArtworkView(url: track.artworkURL, size: 54)
                                        Text(track.title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }.frame(maxWidth: .infinity, alignment: .leading).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if !library.favorites.isEmpty {
                        sectionTitle("Made for you")
                        TrackList(tracks: Array(library.favorites.prefix(8)), showPlayer: $showPlayer)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Find your next favorite").font(.title2.bold())
                        Text("Discover Audius and Internet Archive recordings, or connect your own music server.").foregroundStyle(.secondary)
                        Label("Audius + Internet Archive catalogs", systemImage: "globe.americas.fill").font(.subheadline.weight(.medium)).padding(.top, 4)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(LinearGradient(colors: [Color.blue.opacity(0.28), Color.purple.opacity(0.17)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
                }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 120)
            }
            .background(Color(uiColor: .systemBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func sectionTitle(_ title: String) -> some View { Text(title).font(.title2.bold()) }
}

struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var appleMusic: AppleMusicAccount
    @EnvironmentObject private var spotify: SpotifyAccount
    @Binding var showPlayer: Bool
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var appleSongs: [Song] = []
    @State private var spotifyTracks: [SpotifyTrackSummary] = []
    @State private var isSearching = false
    @State private var error: String?
    @State private var actionError: String?
    private let service = ServerService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Songs, artists, albums, or a stream URL", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    if !query.isEmpty { Button { query = ""; results = []; appleSongs = []; spotifyTracks = [] } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
                }.padding(13).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15)).padding(.horizontal)

                if isSearching { ProgressView("Searching connected music sources…").padding(.top, 24) }
                else if let error, results.isEmpty && appleSongs.isEmpty && spotifyTracks.isEmpty {
                    ContentUnavailableView("Couldn't search", systemImage: "wifi.exclamationmark", description: Text(error))
                } else if results.isEmpty && appleSongs.isEmpty && spotifyTracks.isEmpty {
                    ContentUnavailableView("Search Sonic", systemImage: "waveform", description: Text("Search public catalogs, your servers, Apple Music and Spotify. Connect accounts in Settings."))
                } else {
                    List {
                        if !results.isEmpty {
                            Section("Sonic & personal servers") {
                                ForEach(results) { track in
                                    HStack(spacing: 10) {
                                        Button {
                                            Task {
                                                await appleMusic.pause()
                                                if spotify.isConnected { try? await spotify.playbackCommand("pause") }
                                                playback.play(track, queue: results)
                                                library.recordPlay(track)
                                                showPlayer = true
                                            }
                                        } label: {
                                            HStack(spacing: 10) {
                                                ArtworkView(url: track.artworkURL, size: 48)
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(.primary)
                                                    Text("\(track.artist) · \(track.sourceName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                                }
                                            }
                                        }.buttonStyle(.plain)
                                        Spacer(minLength: 2)
                                        if track.isDownloadable {
                                            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        if !appleSongs.isEmpty {
                            Section("Apple Music") {
                                ForEach(appleSongs, id: \.id) { song in
                                    Button {
                                        playback.pause()
                                        Task {
                                            if spotify.isConnected { try? await spotify.playbackCommand("pause") }
                                            do { try await appleMusic.play(song) } catch { actionError = error.localizedDescription }
                                        }
                                    } label: {
                                        HStack(spacing: 10) {
                                            ArtworkView(url: song.artwork?.url(width: 100, height: 100), size: 48)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                                Text(song.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer(); Image(systemName: "applelogo").foregroundStyle(.secondary)
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        if !spotifyTracks.isEmpty {
                            Section("Spotify · plays in Spotify") {
                                ForEach(spotifyTracks) { track in
                                    Button {
                                        playback.pause()
                                        Task {
                                            await appleMusic.pause()
                                            do { try await spotify.play(uri: track.uri) } catch { actionError = error.localizedDescription }
                                        }
                                    } label: {
                                        HStack(spacing: 10) {
                                            ArtworkView(url: track.artworkURL, size: 48)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer(); Image(systemName: "waveform").foregroundStyle(.secondary)
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        if let error { Section { Text(error).font(.caption).foregroundStyle(.secondary) } }
                    }.listStyle(.insetGrouped)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("All public catalogs", systemImage: "globe") { Task { await search() } }
                        Button("Internet Archive", systemImage: "globe.americas") { Task { await search(source: library.sources.first(where: { $0.kind == .internetArchive }) ?? MusicSource(name: "Internet Archive", kind: .internetArchive)) } }
                        Button("Audius", systemImage: "waveform") { Task { await search(source: library.sources.first(where: { $0.kind == .audius }) ?? MusicSource(name: "Audius", kind: .audius)) } }
                        ForEach(library.sources.filter { $0.kind != .internetArchive && $0.kind != .audius }) { source in Button(source.name) { Task { await search(source: source) } } }
                    } label: { Image(systemName: "slider.horizontal.3") }
                }
            }
            .alert("Sonic", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) { actionError = nil }
            } message: { Text(actionError ?? "") }
        }
    }

    @MainActor private func search(source: MusicSource? = nil) async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true; error = nil; results = []; appleSongs = []; spotifyTracks = []
        defer { isSearching = false }
        if let source {
            do { results = try await service.search(query, on: source) }
            catch { self.error = error.localizedDescription }
            return
        }
        let archive = library.sources.first(where: { $0.kind == .internetArchive }) ?? MusicSource(name: "Internet Archive", kind: .internetArchive)
        let audius = library.sources.first(where: { $0.kind == .audius }) ?? MusicSource(name: "Audius", kind: .audius)
        let archiveTracks = (try? await service.search(query, on: archive)) ?? []
        let audiusTracks = (try? await service.search(query, on: audius)) ?? []
        results = archiveTracks + audiusTracks
        if appleMusic.authorizationStatus == .authorized {
            do {
                let response = try await appleMusic.search(query)
                appleSongs = Array(response.songs)
            } catch { self.error = "Apple Music: \(error.localizedDescription)" }
        }
        if spotify.isConnected {
            do { spotifyTracks = try await spotify.searchTracks(query) }
            catch { self.error = "Spotify: \(error.localizedDescription)" }
        }
        if results.isEmpty && appleSongs.isEmpty && spotifyTracks.isEmpty && error == nil { error = "No results found in your connected sources." }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @Binding var showPlayer: Bool
    @Binding var showImporter: Bool
    @State private var selection = "Downloads"
    @State private var showingCreatePlaylist = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Library", selection: $selection) {
                    Text("Downloads").tag("Downloads")
                    Text("Liked").tag("Favorites")
                    Text("Recent").tag("Recent")
                    Text("Playlists").tag("Playlists")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if selection == "Playlists" {
                    playlistContent
                } else {
                    let tracks = selection == "Downloads" ? library.downloads : selection == "Favorites" ? library.favorites : library.recentlyPlayed
                    if tracks.isEmpty {
                        ContentUnavailableView(selection == "Downloads" ? "Nothing downloaded" : "No music yet", systemImage: "music.note.list", description: Text("Search for music or import audio files."))
                    } else {
                        TrackList(tracks: tracks, showPlayer: $showPlayer)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .navigationTitle("Your Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showImporter = true } label: { Label("Import audio", systemImage: "plus") }
                        Button { showingCreatePlaylist = true } label: { Label("New playlist", systemImage: "music.note.list") }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingCreatePlaylist) { CreatePlaylistView().environmentObject(library) }
        }
    }

    @ViewBuilder private var playlistContent: some View {
        if library.playlists.isEmpty {
            ContentUnavailableView("No playlists yet", systemImage: "music.note.list", description: Text("Create a playlist and organize it into folders."))
        } else {
            let grouped = Dictionary(grouping: library.playlists.keys.sorted(), by: { name in
                let folder = library.playlistFolders[name] ?? ""
                return folder.isEmpty ? "Playlists" : folder
            })
            List {
                ForEach(grouped.keys.sorted(), id: \.self) { folder in
                    Section(folder) {
                        ForEach(grouped[folder] ?? [], id: \.self) { name in
                            NavigationLink {
                                PlaylistDetailView(name: name, showPlayer: $showPlayer)
                            } label: {
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial).frame(width: 44, height: 44)
                                        .overlay(Image(systemName: "music.note.list").foregroundStyle(.cyan))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(name).font(.subheadline.weight(.semibold))
                                        Text("\(library.playlists[name]?.count ?? 0) songs").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            let names = grouped[folder] ?? []
                            for index in offsets where names.indices.contains(index) { library.deletePlaylist(named: names[index]) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}

struct TrackList: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    let tracks: [Track]
    @Binding var showPlayer: Bool
    @State private var downloadingID: String?
    @State private var error: String?
    @State private var showingCreatePlaylist = false
    var body: some View {
        List {
            ForEach(tracks) { track in
                HStack(spacing: 12) {
                    Button { playback.play(track, queue: tracks); library.recordPlay(track); showPlayer = true } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: track.artworkURL, size: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(.primary)
                                Text("\(track.artist) · \(track.sourceName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if let format = track.format { Text(format).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.cyan) }
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Menu {
                        Button(library.isFavorite(track) ? "Remove favorite" : "Add to favorites", systemImage: "heart") { library.toggleFavorite(track) }
                        if track.isDownloadable { Button("Download", systemImage: "arrow.down.circle") { Task { await download(track) } } }
                        if !library.playlists.isEmpty {
                            Menu("Add to playlist", systemImage: "text.badge.plus") {
                                ForEach(library.playlists.keys.sorted(), id: \.self) { name in
                                    Button(name) { library.addToPlaylist(track, named: name) }
                                }
                            }
                        } else {
                            Button("Create playlist", systemImage: "music.note.list") { showingCreatePlaylist = true }
                        }
                    } label: { Image(systemName: downloadingID == track.id ? "arrow.down.circle.fill" : "ellipsis").foregroundStyle(.secondary).padding(8) }
                }.listRowBackground(Color.clear)
            }
        }.listStyle(.plain)
            .sheet(isPresented: $showingCreatePlaylist) { CreatePlaylistView().environmentObject(library) }
            .alert("Sonic", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    @MainActor private func download(_ track: Track) async {
        downloadingID = track.id; defer { downloadingID = nil }
        do { try await library.download(track) } catch { self.error = error.localizedDescription }
    }
}


struct PlaylistDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    let name: String
    @Binding var showPlayer: Bool
    var body: some View {
        Group {
            if let tracks = library.playlists[name], !tracks.isEmpty {
                TrackList(tracks: tracks, showPlayer: $showPlayer)
            } else {
                ContentUnavailableView("This playlist is empty", systemImage: "music.note.list", description: Text("Add songs from your library or search results."))
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CreatePlaylistView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Folder (optional)", text: $folder)
                        .textInputAutocapitalization(.words)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                Section {
                    Text("Folders keep your playlists organized without adding extra navigation layers.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        if library.createPlaylist(name: name, folder: folder) { dismiss() }
                        else { errorMessage = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Enter a playlist name." : "A playlist with that name already exists." }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct ArtworkView: View {
    let url: URL?
    var size: CGFloat = 56
    var body: some View {
        Group {
            if let url { AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { placeholder }
            } } else { placeholder }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.17)).overlay(RoundedRectangle(cornerRadius: size * 0.17).stroke(.white.opacity(0.08), lineWidth: 1))
    }
    private var placeholder: some View { ZStack { LinearGradient(colors: [.indigo.opacity(0.8), .cyan.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: "waveform").font(.title2).foregroundStyle(.white.opacity(0.9)) } }
}

struct MiniPlayer: View {
    @EnvironmentObject private var playback: PlaybackManager
    @Binding var showPlayer: Bool
    var body: some View {
        Button { showPlayer = true } label: {
            HStack(spacing: 10) {
                ArtworkView(url: playback.currentTrack?.artworkURL, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playback.currentTrack?.title ?? "Not playing").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(playback.currentTrack?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { playback.previous() } label: { Image(systemName: "backward.fill").font(.title3) }.buttonStyle(.plain)
                Button { playback.togglePlayback() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(width: 36) }.buttonStyle(.plain)
                Button { playback.next() } label: { Image(systemName: "forward.fill").font(.title3) }.buttonStyle(.plain)
            }.padding(.horizontal, 12).padding(.vertical, 9).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.12), lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var showLyrics = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle()) }
                Spacer()
                VStack(spacing: 2) { Text("PLAYING FROM").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(.secondary); Text(playback.currentTrack?.sourceName ?? "Sonic").font(.caption.weight(.semibold)) }
                Spacer()
                HStack(spacing: 8) {
                    Button { showLyrics = true } label: { Image(systemName: "quote.bubble").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle()) }
                    Button { showQueue = true } label: { Image(systemName: "list.bullet").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle()) }
                }
            }.padding(.horizontal, 22).padding(.top, 14)
            Spacer(minLength: 20)
            ArtworkView(url: playback.currentTrack?.artworkURL, size: 310)
                .frame(maxWidth: .infinity).shadow(color: .black.opacity(0.35), radius: 25, y: 15)
            Spacer(minLength: 24)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(playback.currentTrack?.title ?? "Choose a song").font(.title2.bold()).lineLimit(1)
                    Text(playback.currentTrack?.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let track = playback.currentTrack {
                    Button { library.toggleFavorite(track) } label: { Image(systemName: library.isFavorite(track) ? "heart.fill" : "heart").font(.title2).foregroundStyle(library.isFavorite(track) ? .pink : .primary) }
                }
            }.padding(.horizontal, 28)
            VStack(spacing: 5) {
                Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }), in: 0...max(playback.duration, 1))
                    .tint(.cyan)
                HStack { Text(time(playback.currentTime)); Spacer(); Text("-\(time(max(0, playback.duration - playback.currentTime)))") }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.top, 22)
            HStack(spacing: 42) {
                Button { playback.previous() } label: { Image(systemName: "backward.end.fill").font(.title2) }
                Button { playback.togglePlayback() } label: { Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 70)).symbolRenderingMode(.hierarchical) }
                Button { playback.next() } label: { Image(systemName: "forward.end.fill").font(.title2) }
            }.padding(.top, 18)
            HStack(spacing: 54) {
                Button { playback.isShuffling.toggle() } label: {
                    Image(systemName: "shuffle").font(.title3).foregroundStyle(playback.isShuffling ? .cyan : .secondary)
                }.accessibilityLabel(playback.isShuffling ? "Turn shuffle off" : "Turn shuffle on")
                Button { cycleRepeatMode() } label: {
                    .foregroundStyle(
                    playback.repeatMode == .off
                        ? Color.secondary
                        : Color.cyan
)
                }.accessibilityLabel(playback.repeatMode.label)
            }.padding(.top, 12)
            Menu {
                ForEach(PlaybackRate.presets, id: \.self) { speed in
                    Button { playback.setPlaybackSpeed(speed) } label: {
                        if playback.playbackSpeed == speed {
                            Label("\(speed.formatted(.number.precision(.fractionLength(0...2))))×", systemImage: "checkmark")
                        } else {
                            Text("\(speed.formatted(.number.precision(.fractionLength(0...2))))×")
                        }
                    }
                }
            } label: {
                Label("\(playback.playbackSpeed.formatted(.number.precision(.fractionLength(0...2))))×", systemImage: "speedometer")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .accessibilityLabel("Playback speed")
            .padding(.top, 10)
            HStack {
                Label(playback.currentTrack?.format ?? "Streaming", systemImage: "waveform")
                Spacer()
                Text(playback.currentTrack?.bitrateLabel ?? "Source metadata unavailable").foregroundStyle(.secondary)
            }.font(.caption2).padding(.horizontal, 28).padding(.top, 24)
            Spacer(minLength: 24)
        }
        .background {
            ZStack {
                Color(uiColor: .systemBackground)
                if let url = playback.currentTrack?.artworkURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill().blur(radius: 65).opacity(0.22)
                    } placeholder: { Color.clear }
                    .ignoresSafeArea()
                }
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showQueue) {
            NavigationStack {
                List {
                    ForEach(playback.queue.indices, id: \.self) { index in
                        let track = playback.queue[index]
                        HStack {
                            ArtworkView(url: track.artworkURL, size: 42)
                            VStack(alignment: .leading) { Text(track.title); Text(track.artist).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if index == playback.queueIndex { Image(systemName: "waveform").foregroundStyle(.cyan) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { playback.play(track, queue: playback.queue) }
                        .swipeActions { Button(role: .destructive) { playback.removeQueueItem(at: index) } label: { Label("Remove", systemImage: "trash") } }
                    }
                    .onMove { playback.moveQueue(from: $0, to: $1) }
                }
                .navigationTitle("Up Next")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showLyrics) { LyricsView().environmentObject(playback).presentationDetents([.large]) }
    }
    private func cycleRepeatMode() {
        switch playback.repeatMode {
        case .off: playback.repeatMode = .all
        case .all: playback.repeatMode = .one
        case .one: playback.repeatMode = .off
        }
    }
    private func time(_ value: Double) -> String { guard value.isFinite else { return "0:00" }; return String(format: "%d:%02d", Int(value) / 60, Int(value) % 60) }
}

struct SourcesView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showingAdd = false
    var body: some View {
        NavigationStack {
            List {
                Section("Public catalog") {
                    Label("Internet Archive + Audius", systemImage: "globe.americas.fill")
                    Text("Search Audius and Internet Archive public catalogs. Download availability depends on the track and provider permissions.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Your servers") {
                    ForEach(library.sources.filter { $0.kind != .internetArchive && $0.kind != .audius }) { source in
                        VStack(alignment: .leading, spacing: 4) { Text(source.name).font(.headline); Text("\(source.kind.rawValue) · \(source.baseURL?.absoluteString ?? "Direct URL")").font(.caption).foregroundStyle(.secondary) }
                    }.onDelete { offsets in
                        let custom = library.sources.filter { $0.kind != .internetArchive && $0.kind != .audius }
                        let removed = offsets.map { custom[$0].id }
                        library.sources.removeAll { removed.contains($0.id) }
                    }
                }
                Section { Button { showingAdd = true } label: { Label("Add a music source", systemImage: "plus.circle.fill") } }
                Section("About audio") {
                    Label("Original stream", systemImage: "waveform")
                    Text("Sonic requests the source's original audio stream when available. Actual codecs and output quality depend on the provider, file, iOS decoder and audio device.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Music Sources").toolbar { EditButton() }
        }.sheet(isPresented: $showingAdd) { AddSourceView().environmentObject(library) }
    }
}

struct AddSourceView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: MusicSource.Kind = .subsonic
    @State private var name = "My Music Server"
    @State private var url = "https://"
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var userID = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") { Picker("Type", selection: $kind) { Text("Subsonic / Navidrome").tag(MusicSource.Kind.subsonic); Text("Jellyfin").tag(MusicSource.Kind.jellyfin); Text("Direct stream URL").tag(MusicSource.Kind.direct) }; TextField("Display name", text: $name) }
                Section("Connection") {
                    TextField(kind == .direct ? "Stream URL" : "Server URL", text: $url).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    if kind == .subsonic { TextField("Username", text: $username).textInputAutocapitalization(.never); SecureField("Password", text: $password) }
                    if kind == .jellyfin { TextField("API key", text: $apiKey); TextField("Jellyfin user ID", text: $userID) }
                }
                if kind == .jellyfin { Section { Text("Create an API key in your Jellyfin dashboard. Copy your user ID from the Jellyfin user details. Sonic uses the server's audio stream endpoint.").font(.caption).foregroundStyle(.secondary) } }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Add Source").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }
    private func save() {
        guard let parsed = URL(string: url), parsed.scheme == "https" || parsed.scheme == "http" else { error = "Enter a valid http or https URL."; return }
        let source = MusicSource(name: name.isEmpty ? kind.rawValue : name, kind: kind, baseURL: parsed, username: username, password: password, apiKey: apiKey, userID: userID)
        library.addSource(source); dismiss()
    }
}
