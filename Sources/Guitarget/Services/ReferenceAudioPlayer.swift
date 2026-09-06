import Foundation
import AVFoundation
import Combine
import GuitarAudio

/// A selected local recording, sharing the app's single audible output slot.
@MainActor
final class ReferenceAudioPlayer: ObservableObject {
    @Published private(set) var entryID: UUID?
    @Published private(set) var ownerID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var rate: Double = 1
    @Published var error: String?
    private var player: AVAudioPlayer?
    private var loadedURL: URL?
    private var timer: AnyCancellable?
    private let volume: Float
    private let playbackToken = UUID()
    private let playbackCoordinator: PlaybackCoordinator

    init(volume: Float = 1, playbackCoordinator: PlaybackCoordinator? = nil) {
        self.volume = volume
        self.playbackCoordinator = playbackCoordinator ?? .shared
    }

    /// Selecting a source loads its duration without starting playback. Moving a
    /// recording to another window pauses it while retaining the playback position.
    @discardableResult
    func prepare(id: UUID, url: URL, owner: String? = nil) -> Bool {
        let canonicalURL = url.standardizedFileURL
        if entryID == id, loadedURL == canonicalURL, player != nil {
            if ownerID != owner { pause(); ownerID = owner }
            error = nil
            return true
        }
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            guard next.duration.isFinite, next.duration > 0 else { throw LibraryUIError("音频没有可播放的内容。") }
            next.volume = volume
            next.enableRate = true
            next.rate = Float(rate)
            guard next.prepareToPlay() else { throw LibraryUIError("系统无法载入这份音频。") }
            stop()
            player = next; loadedURL = canonicalURL; entryID = id; ownerID = owner
            duration = next.duration; error = nil
            timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                guard let self, let player = self.player, self.isPlaying else { return }
                if player.isPlaying {
                    self.currentTime = min(player.currentTime, self.duration)
                } else {
                    self.isPlaying = false
                    self.currentTime = self.duration
                    self.playbackCoordinator.release(token: self.playbackToken)
                }
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func toggle(id: UUID, url: URL, owner: String? = nil) {
        let wasPlaying = entryID == id && ownerID == owner && loadedURL == url.standardizedFileURL && isPlaying
        guard prepare(id: id, url: url, owner: owner) else { return }
        if wasPlaying { pause() } else { play() }
    }

    @discardableResult
    func play() -> Bool {
        guard let player else { return false }
        guard playbackCoordinator.acquire(token: playbackToken, interrupt: { [weak self] in self?.pause() }) else { return false }
        if currentTime >= duration { player.currentTime = 0; currentTime = 0 }
        isPlaying = player.play()
        if isPlaying { error = nil }
        else {
            playbackCoordinator.release(token: playbackToken)
            error = "系统无法播放这份音频。"
        }
        return isPlaying
    }

    func pause() {
        guard let player else { return }
        player.pause()
        if isPlaying { currentTime = min(player.currentTime, duration) }
        isPlaying = false
        playbackCoordinator.release(token: playbackToken)
    }

    func restart() {
        seek(0)
        play()
    }

    func setRate(_ value: Double) {
        rate = value.isFinite ? min(2, max(0.5, value)) : 1
        player?.rate = Float(rate)
    }
    func seek(_ time: TimeInterval) {
        guard time.isFinite else { return }
        player?.currentTime = min(max(0, time), duration)
        currentTime = player?.currentTime ?? 0
    }
    func stop() {
        player?.stop(); player = nil; loadedURL = nil; timer?.cancel(); timer = nil
        playbackCoordinator.release(token: playbackToken)
        entryID = nil; ownerID = nil; isPlaying = false; currentTime = 0; duration = 0
    }
}
