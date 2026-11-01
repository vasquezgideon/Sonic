import SwiftUI
import MusicKit

struct SettingsView: View {
    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var spotify: SpotifyAccount
    @EnvironmentObject private var appleMusic: AppleMusicAccount
    @EnvironmentObject private var library: LibraryStore
    @State private var spotifyClientID = ""
    @State private var appleSearch = ""
    @State private var appleSongs: [Song] = []
    @State private var isSearchingApple = false
    @State private var showMashup = false
    @State private var alertMessage: String?
    @AppStorage("sonic.theme") private var theme = "dark"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.circle.fill").font(.system(size: 38)).foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Sonic").font(.title3.bold())
                            Text("Your music, your mix.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("1.3").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }

                Section("Connected music services") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Apple Music", systemImage: "applelogo").font(.headline)
                        Text(appleMusic.statusMessage).font(.caption).foregroundStyle(.secondary)
                        Button { Task { await appleMusic.connect() } } label: {
                            Label(appleMusic.authorizationStatus == .authorized ? "Refresh Apple Music access" : "Connect Apple Music", systemImage: "link")
                        }
                        if appleMusic.authorizationStatus == .authorized {
                            HStack {
                                TextField("Search Apple Music catalog", text: $appleSearch).textInputAutocapitalization(.never)
                                Button { Task { await searchAppleMusic() } } label: { Image(systemName: "magnifyingglass") }.disabled(appleSearch.isEmpty || isSearchingApple)
                            }
                            if isSearchingApple { ProgressView() }
                            ForEach(appleSongs.prefix(6), id: \.id) { song in
                                Button {
                                    playback.pause()
                                    Task {
                                        if spotify.isConnected { try? await spotify.playbackCommand("pause") }
                                        do { try await appleMusic.play(song) } catch { alertMessage = error.localizedDescription }
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        ArtworkView(url: song.artwork?.url(width: 100, height: 100), size: 42)
                                        VStack(alignment: .leading) { Text(song.title).lineLimit(1); Text(song.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                        Spacer(); Image(systemName: "play.circle.fill").foregroundStyle(.tint)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }.padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Spotify", systemImage: "waveform").font(.headline)
                        Text(spotify.statusMessage).font(.caption).foregroundStyle(.secondary)
                        if spotify.isConnected {
                            if let displayName = spotify.displayName { Text(displayName).font(.subheadline.weight(.medium)) }
                            HStack {
                                Button { Task { do { try await spotify.playbackCommand("previous") } catch { alertMessage = error.localizedDescription } } } label: { Image(systemName: "backward.fill") }
                                Button {
                                    playback.pause()
                                    Task { await appleMusic.pause(); do { try await spotify.playbackCommand("play") } catch { alertMessage = error.localizedDescription } }
                                } label: { Image(systemName: "play.fill") }
                                Button { Task { do { try await spotify.playbackCommand("pause") } catch { alertMessage = error.localizedDescription } } } label: { Image(systemName: "pause.fill") }
                                Button { Task { do { try await spotify.playbackCommand("next") } catch { alertMessage = error.localizedDescription } } } label: { Image(systemName: "forward.fill") }
                                Spacer()
                                Button("Disconnect", role: .destructive) { spotify.disconnect() }
                            }.buttonStyle(.bordered)
                        } else {
                            SecureField("Spotify Developer Client ID", text: $spotifyClientID).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button { connectSpotify() } label: { Label("Connect Spotify", systemImage: "link") }
                            Text("Create a Spotify developer app and register sonic://spotify-callback as its redirect URI. Spotify playback is controlled through the official Spotify app / Spotify Connect; Sonic does not extract or rehost Spotify audio.").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }

                Section("Playback feel") {
                    HStack {
                        Label("Playback speed", systemImage: "speedometer")
                        Spacer()
                        Text("\(playback.playbackSpeed.formatted(.number.precision(.fractionLength(0...2))))×")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { playback.playbackSpeed }, set: { playback.setPlaybackSpeed($0) }), in: 0.5...2.0, step: 0.05)
                    Text("Adjust Sonic's own player from half speed to double speed. Protected Apple Music and Spotify playback use their own players and controls.").font(.caption2).foregroundStyle(.secondary)
                    Toggle(isOn: $playback.beatHapticsEnabled) {
                        Label("Beat haptics", systemImage: "waveform.path")
                    }
                    if playback.beatHapticsEnabled {
                        VStack(alignment: .leading) {
                            HStack { Text("Haptic tempo"); Spacer(); Text("\(Int(playback.hapticBPM)) BPM").monospacedDigit().foregroundStyle(.secondary) }
                            Slider(value: $playback.hapticBPM, in: 40...200, step: 1)
                        }
                        Text("Pulses a gentle haptic on the selected beat while Sonic's own player is active. It is a tempo guide, not automatic beat detection.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Menu {
                        Button("Off") { playback.setSleepTimer(minutes: nil) }
                        Button("After current track") { playback.setSleepTimerAtTrackEnd() }
                        ForEach([15, 30, 45, 60, 90], id: \.self) { value in Button("\(value) minutes") { playback.setSleepTimer(minutes: value) } }
                    } label: {
                        HStack { Label("Sleep timer", systemImage: "moon.zzz"); Spacer(); Text(playback.sleepTimerLabel ?? "Off").foregroundStyle(.secondary) }
                    }
                }

                Section("Sonic Studio") {
                    Button { showMashup = true } label: {
                        Label { VStack(alignment: .leading) { Text("Mashup Studio"); Text("Mix two local tracks with independent volume controls").font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: "slider.horizontal.3").foregroundStyle(.purple) }
                    }
                    Text("Mashup mixing is for local files and downloads you have permission to use. Streaming-service tracks remain inside their provider's player and cannot be captured or remixed by Sonic.").font(.caption2).foregroundStyle(.secondary)
                }

                Section("Appearance") {
                    Picker("Theme", selection: $theme) {
                        Text("Dark").tag("dark"); Text("Light").tag("light"); Text("System").tag("system")
                    }.pickerStyle(.segmented)
                    Text("Sonic keeps advanced tools here so the main music screens stay uncluttered.").font(.caption).foregroundStyle(.secondary)
                }

                Section("About integrations") {
                    Text("Apple Music uses MusicKit authorization and catalog playback. Spotify uses OAuth authorization and supported Web API / Spotify Connect controls. Service features depend on subscriptions, developer access, region and provider policies.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showMashup) { MashupStudioView().environmentObject(library).presentationDetents([.large]) }
            .alert("Sonic", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) { Button("OK", role: .cancel) { alertMessage = nil } } message: { Text(alertMessage ?? "") }
            .onAppear { spotifyClientID = KeychainStore.get("spotify-client-id") ?? "" }
        }
    }

    private func connectSpotify() {
        do {
            let url = try spotify.authorizationURL(clientID: spotifyClientID)
            UIApplication.shared.open(url)
        } catch { alertMessage = error.localizedDescription }
    }

    private func searchAppleMusic() async {
        isSearchingApple = true
        defer { isSearchingApple = false }
        do {
            let response = try await appleMusic.search(appleSearch)
            appleSongs = Array(response.songs ?? [])
        } catch { alertMessage = error.localizedDescription }
    }
}

struct MashupStudioView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackManager
    @EnvironmentObject private var appleMusic: AppleMusicAccount
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mixer = MashupEngine()
    @State private var leftID = ""
    @State private var rightID = ""

    private var localTracks: [Track] { library.downloads.filter { library.downloadedURL(for: $0) != nil } }
    private var leftTrack: Track? { localTracks.first { $0.id == leftID } }
    private var rightTrack: Track? { localTracks.first { $0.id == rightID } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.badge.plus").font(.system(size: 48)).foregroundStyle(.purple)
                        Text("Mashup Studio").font(.title2.bold())
                        Text("Start two local audio files together and blend their levels.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                Section("Deck A") {
                    Picker("Track", selection: $leftID) { Text("Choose a track").tag(""); ForEach(localTracks) { Text("\($0.title) — \($0.artist)").tag($0.id) } }
                    HStack { Text("Level"); Slider(value: $mixer.leftGain, in: 0...1); Text("\(Int(mixer.leftGain * 100))%").monospacedDigit().frame(width: 42) }
                }
                Section("Deck B") {
                    Picker("Track", selection: $rightID) { Text("Choose a track").tag(""); ForEach(localTracks) { Text("\($0.title) — \($0.artist)").tag($0.id) } }
                    HStack { Text("Level"); Slider(value: $mixer.rightGain, in: 0...1); Text("\(Int(mixer.rightGain * 100))%").monospacedDigit().frame(width: 42) }
                }
                Section {
                    Button { startMix() } label: { Label("Play mashup", systemImage: "play.fill").frame(maxWidth: .infinity) }.disabled(leftTrack == nil || rightTrack == nil || leftID == rightID)
                    Button(role: .destructive) { mixer.stop() } label: { Label("Stop both decks", systemImage: "stop.fill").frame(maxWidth: .infinity) }.disabled(!mixer.isPlaying)
                    if mixer.isPlaying { Label("Both decks playing", systemImage: "waveform").foregroundStyle(.green) }
                    if let error = mixer.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                }
                if localTracks.isEmpty {
                    ContentUnavailableView("No local tracks yet", systemImage: "music.note", description: Text("Download or import audio files first. Only local files are available in the mixer."))
                }
            }
            .navigationTitle("Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { mixer.stop(); dismiss() } } }
            .onAppear {
                if leftID.isEmpty { leftID = localTracks.first?.id ?? "" }
                if rightID.isEmpty { rightID = localTracks.dropFirst().first?.id ?? "" }
            }
            .onDisappear { mixer.stop() }
        }
    }

    private func startMix() {
        guard let a = leftTrack, let b = rightTrack,
              let urlA = library.downloadedURL(for: a), let urlB = library.downloadedURL(for: b) else { return }
        playback.pause()
        Task { await appleMusic.pause() }
        mixer.play(leftURL: urlA, rightURL: urlB)
    }
}

struct LyricsView: View {
    @EnvironmentObject private var playback: PlaybackManager
    @Environment(\.dismiss) private var dismiss
    @State private var result: LyricsResult?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var activeLineID: Int? {
        guard let lines = result?.lines else { return nil }
        return lines.last(where: { $0.time <= playback.currentTime })?.id
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Finding lyrics…")
                } else if let lines = result?.lines, !lines.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 22) {
                                ForEach(lines) { line in
                                    Text(line.text.isEmpty ? "♪" : line.text)
                                        .font(.system(size: activeLineID == line.id ? 25 : 20, weight: activeLineID == line.id ? .bold : .medium, design: .rounded))
                                        .foregroundStyle(activeLineID == line.id ? .primary : .secondary)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                        .id(line.id)
                                }
                            }.padding(24)
                        }
                        .onChange(of: activeLineID) { _, newValue in
                            guard let newValue else { return }
                            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(newValue, anchor: .center) }
                        }
                        .onAppear {
                            if let activeLineID { proxy.scrollTo(activeLineID, anchor: .center) }
                        }
                    }
                } else if let text = result?.plainText, !text.isEmpty {
                    ScrollView { Text(text).font(.title3.weight(.medium)).lineSpacing(9).frame(maxWidth: .infinity, alignment: .leading).padding(24) }
                } else {
                    ContentUnavailableView("Lyrics unavailable", systemImage: "text.quote", description: Text(errorMessage ?? "No lyrics were found for this track."))
                }
            }
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: playback.currentTrack?.id) { await loadLyrics() }
        }
    }

    @MainActor private func loadLyrics() async {
        guard let track = playback.currentTrack else { result = nil; return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do { result = try await LyricsService().fetch(for: track) }
        catch { errorMessage = error.localizedDescription; result = nil }
    }
}
