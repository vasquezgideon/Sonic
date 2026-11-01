import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit
import MusicKit

enum RepeatMode: String, CaseIterable, Identifiable {
    case off, all, one
    var id: String { rawValue }
    var label: String { switch self { case .off: return "Repeat off"; case .all: return "Repeat all"; case .one: return "Repeat one" } }
    var icon: String { switch self { case .off: return "repeat"; case .all: return "repeat"; case .one: return "repeat.1" } }
}

@MainActor
final class PlaybackManager: ObservableObject {
    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var queue: [Track] = []
    @Published var queueIndex: Int = 0
    @Published var isShuffling = UserDefaults.standard.bool(forKey: "sonic.shuffle") {
        didSet { UserDefaults.standard.set(isShuffling, forKey: "sonic.shuffle") }
    }
    @Published var repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "sonic.repeat") ?? "all") ?? .all {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "sonic.repeat") }
    }
    @Published var errorMessage: String?
    @Published private(set) var playbackSpeed: Double = {
        let saved = UserDefaults.standard.double(forKey: "sonic.playbackSpeed")
        return saved == 0 ? 1.0 : PlaybackRate.clamped(saved)
    }()
    @Published var beatHapticsEnabled = UserDefaults.standard.bool(forKey: "sonic.beatHaptics") {
        didSet { UserDefaults.standard.set(beatHapticsEnabled, forKey: "sonic.beatHaptics") }
    }
    @Published var hapticBPM: Double = UserDefaults.standard.double(forKey: "sonic.hapticBPM") == 0 ? 100 : UserDefaults.standard.double(forKey: "sonic.hapticBPM") {
        didSet { UserDefaults.standard.set(hapticBPM, forKey: "sonic.hapticBPM") }
    }
    @Published private(set) var sleepTimerLabel: String?
    @Published private(set) var sleepAtTrackEnd = false
    private var sleepTask: Task<Void, Never>?
    private var lastHapticBeat = -1

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?
    private var artworkTask: Task<Void, Never>?

    init() { configureAudioSession(); configureRemoteCommands() }

    func play(_ track: Track, queue tracks: [Track] = []) {
        queue = tracks.isEmpty ? [track] : tracks
        queueIndex = max(0, queue.firstIndex(where: { $0.id == track.id }) ?? 0)
        start(track)
    }

    private func start(_ track: Track) {
        ApplicationMusicPlayer.shared.pause()
        artworkTask?.cancel()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let itemEndObserver { NotificationCenter.default.removeObserver(itemEndObserver); self.itemEndObserver = nil }
        currentTrack = track
        currentTime = 0; duration = track.duration ?? 0; lastHapticBeat = -1
        let item = AVPlayerItem(url: track.streamURL)
        item.audioTimePitchAlgorithm = .spectral
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        player = newPlayer
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                let itemDuration = newPlayer.currentItem?.duration.seconds ?? 0
                if itemDuration.isFinite && itemDuration > 0 { self.duration = itemDuration }
                self.updatePlaybackInfo()
                self.pulseHapticIfNeeded(at: self.currentTime)
            }
        }
        itemEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.sleepAtTrackEnd {
                    self.sleepAtTrackEnd = false
                    self.sleepTimerLabel = nil
                    self.pause()
                } else {
                    self.next()
                }
            }
        }
        newPlayer.playImmediately(atRate: Float(playbackSpeed))
        isPlaying = true
        updatePlaybackInfo()
        artworkTask = Task { await loadArtwork(for: track) }
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else { player.playImmediately(atRate: Float(playbackSpeed)); isPlaying = true }
        updatePlaybackInfo()
    }

    func pause() { player?.pause(); isPlaying = false; updatePlaybackInfo() }

    /// Changes the native AVPlayer rate without altering the source file or transcoding audio.
    func setPlaybackSpeed(_ value: Double) {
        let safeValue = PlaybackRate.clamped(value)
        playbackSpeed = safeValue
        UserDefaults.standard.set(safeValue, forKey: "sonic.playbackSpeed")
        if isPlaying { player?.rate = Float(safeValue) }
        updatePlaybackInfo()
    }

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel(); sleepTask = nil; sleepTimerLabel = nil; sleepAtTrackEnd = false
        guard let minutes, minutes > 0 else { return }
        sleepTimerLabel = "\(minutes) min"
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self else { return }
            let startingVolume = self.player?.volume ?? 1
            for step in 0..<20 {
                if Task.isCancelled { self.player?.volume = startingVolume; return }
                self.player?.volume = startingVolume * (1 - Float(step + 1) / 20)
                try? await Task.sleep(for: .milliseconds(250))
            }
            self.pause()
            self.player?.volume = startingVolume
            self.sleepTimerLabel = nil
        }
    }

    func setSleepTimerAtTrackEnd() {
        sleepTask?.cancel(); sleepTask = nil
        sleepAtTrackEnd = true
        sleepTimerLabel = "After this track"
    }

    private func pulseHapticIfNeeded(at time: Double) {
        guard beatHapticsEnabled, isPlaying, hapticBPM >= 40 else { return }
        let beat = Int(time / (60.0 / hapticBPM))
        guard beat != lastHapticBeat else { return }
        lastHapticBeat = beat
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred(intensity: 0.35)
    }
    func seek(to seconds: Double) { player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) }
    func next() {
        guard !queue.isEmpty else { return }
        if repeatMode == .one, let currentTrack {
            start(currentTrack)
            return
        }
        if isShuffling && queue.count > 1 {
            let choices = queue.indices.filter { $0 != queueIndex }
            queueIndex = choices.randomElement() ?? queueIndex
        } else if queueIndex + 1 < queue.count {
            queueIndex += 1
        } else if repeatMode == .all {
            queueIndex = 0
        } else {
            pause()
            currentTime = duration
            return
        }
        start(queue[queueIndex])
    }

    func previous() {
        if currentTime > 3 { seek(to: 0); return }
        guard !queue.isEmpty else { return }
        if isShuffling && queue.count > 1 {
            let choices = queue.indices.filter { $0 != queueIndex }
            queueIndex = choices.randomElement() ?? queueIndex
        } else if queueIndex > 0 {
            queueIndex -= 1
        } else if repeatMode == .all {
            queueIndex = queue.count - 1
        } else {
            seek(to: 0)
            return
        }
        start(queue[queueIndex])
    }

    func moveQueue(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }
        let currentID = currentTrack?.id
        let moving = source.sorted().map { queue[$0] }
        var remaining = queue.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let removedBeforeDestination = source.filter { $0 < destination }.count
        let insertion = max(0, min(destination - removedBeforeDestination, remaining.count))
        remaining.insert(contentsOf: moving, at: insertion)
        queue = remaining
        if let currentID, let newIndex = queue.firstIndex(where: { $0.id == currentID }) { queueIndex = newIndex }
    }

    func removeQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let removingCurrent = index == queueIndex
        queue.remove(at: index)
        if queue.isEmpty { queueIndex = 0; pause(); currentTrack = nil; return }
        if index < queueIndex { queueIndex -= 1 }
        if removingCurrent {
            queueIndex = min(queueIndex, queue.count - 1)
            start(queue[queueIndex])
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch { errorMessage = error.localizedDescription }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in guard let self else { return }; self.player?.playImmediately(atRate: Float(self.playbackSpeed)); self.isPlaying = true; self.updatePlaybackInfo() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlayback() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updatePlaybackInfo(artwork: MPMediaItemArtwork? = nil) {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist,
                                   MPMediaItemPropertyAlbumTitle: track.album, MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
                                   MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackSpeed : 0.0]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for track: Track) async {
        guard let url = track.artworkURL else { updatePlaybackInfo(); return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled, let image = UIImage(data: data) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            updatePlaybackInfo(artwork: artwork)
        } catch { /* Artwork is optional; playback should continue. */ }
    }
}
