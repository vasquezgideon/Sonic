import Foundation
import AVFoundation
import Combine

@MainActor
final class MashupEngine: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var leftGain: Double = 0.8 { didSet { leftNode?.volume = Float(leftGain) } }
    @Published var rightGain: Double = 0.8 { didSet { rightNode?.volume = Float(rightGain) } }
    @Published var errorMessage: String?

    private var engine: AVAudioEngine?
    private var leftNode: AVAudioPlayerNode?
    private var rightNode: AVAudioPlayerNode?

    func play(leftURL: URL, rightURL: URL) {
        stop()
        do {
            let leftFile = try AVAudioFile(forReading: leftURL)
            let rightFile = try AVAudioFile(forReading: rightURL)
            let audioEngine = AVAudioEngine()
            let a = AVAudioPlayerNode()
            let b = AVAudioPlayerNode()
            audioEngine.attach(a); audioEngine.attach(b)
            audioEngine.connect(a, to: audioEngine.mainMixerNode, format: leftFile.processingFormat)
            audioEngine.connect(b, to: audioEngine.mainMixerNode, format: rightFile.processingFormat)
            a.volume = Float(leftGain); b.volume = Float(rightGain)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP, .allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
            try audioEngine.start()
            a.scheduleFile(leftFile, at: nil, completionHandler: nil)
            b.scheduleFile(rightFile, at: nil, completionHandler: nil)
            a.play(); b.play()
            engine = audioEngine; leftNode = a; rightNode = b
            isPlaying = true; errorMessage = nil
        } catch {
            errorMessage = "Couldn't mix these files: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        leftNode?.stop(); rightNode?.stop()
        engine?.stop()
        leftNode = nil; rightNode = nil; engine = nil
        isPlaying = false
    }
}
