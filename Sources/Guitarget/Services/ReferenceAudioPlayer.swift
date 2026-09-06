import Foundation
import AVFoundation
import Combine

/// One independent backing recording across library and document windows.
@MainActor
final class ReferenceAudioPlayer: ObservableObject {
    @Published private(set) var entryID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var error: String?
    private var player: AVAudioPlayer?
    private var timer: AnyCancellable?
    private let volume: Float

    init(volume: Float = 1) { self.volume = volume }

    func toggle(id: UUID, url: URL) {
        if entryID == id, let player {
            if player.isPlaying { player.pause(); isPlaying = false }
            else { isPlaying = player.play() }
            return
        }
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.volume = volume
            stop()
            player = next; entryID = id; duration = next.duration
            isPlaying = next.play()
            guard isPlaying else { stop(); throw LibraryUIError("系统无法播放这份音频。") }
            timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if self.isPlaying && !player.isPlaying {
                    self.isPlaying = false
                    self.currentTime = 0
                    player.currentTime = 0
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func seek(_ time: TimeInterval) {
        player?.currentTime = min(max(0, time), duration)
        currentTime = player?.currentTime ?? 0
    }
    func stop() {
        player?.stop(); player = nil; timer?.cancel(); timer = nil
        entryID = nil; isPlaying = false; currentTime = 0; duration = 0
    }
}
