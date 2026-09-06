import SwiftUI
import Combine
import AVFoundation
import GuitarCore
import GuitarAudio

enum ScoreAudioSource: String, Hashable {
    case score, performance, reference
}

@MainActor
extension ScoreEditorState {
    var performanceStatus: String {
        guard follower.isRunning else { return follower.status }
        guard let audio, audio.source == .input, audio.isCapturing else {
            return audio?.isStartingCapture == true ? "正在开启吉他声音输入…" : "等待声音输入 · 请在声音设置中启用麦克风或声卡"
        }
        return follower.status
    }

    var performanceExpectedNote: String? { follower.nextTarget?.title }

    var transportIsPlaying: Bool {
        if audioSource == .reference { return referencePlayer?.ownerID == owner && referencePlayer?.isPlaying == true }
        if audioSource == .performance { return follower.isRunning }
        return audio?.ownerID == owner && audio?.isPlaying == true
    }

    func configureReference(player: ReferenceAudioPlayer, entryID: UUID?, url: URL?) {
        if referencePlayer !== player {
            referencePlayer = player
            referenceSubscription = player.objectWillChange.sink { [weak self] in
                // Read after the player's @Published values have changed.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.audioSource == .reference,
                       player.ownerID != self.owner || !player.isPlaying {
                        self.pauseFollowing()
                    }
                    self.objectWillChange.send()
                }
            }
        }
        if referenceEntryID != entryID || referenceURL != url {
            if audioSource == .reference { selectAudioSource(.score) }
            referenceEntryID = entryID
            referenceURL = url
        }
    }

    func selectAudioSource(_ source: ScoreAudioSource) {
        guard source != audioSource else { return }
        guard source != .reference || (referenceEntryID != nil && referenceURL != nil) else { return }
        stopOwnedPlayback()
        audioSource = source
        follower.reset()
        clearSelection()
        if source == .reference, let id = referenceEntryID, let url = referenceURL {
            if referencePlayer?.prepare(id: id, url: url, owner: owner) != true {
                error = referencePlayer?.error ?? "无法载入附加音频。"
            }
        }
    }

    func togglePerformance() {
        guard let audio else { return }
        if transportIsPlaying {
            if audioSource == .reference { referencePlayer?.pause() }
            pauseFollowing()
            return
        }
        // Transfer the whole performance session synchronously before reusing
        // input. Delayed notifications from the old window can no longer stop it.
        let previous = Self.activePerformer
        Self.activePerformer = self
        if previous !== self { previous?.stopOwnedPlayback() }
        // Input is guitar/microphone audio. A system-audio tap would follow the
        // backing recording instead of the player, so it is never used here.
        if !audio.isCapturing || audio.source != .input {
            previousCaptureSource = audio.source
            captureWasStarted = true
            audio.source = .input
            audio.startCapture()
        }
        if audioSource == .reference {
            guard let id = referenceEntryID, let url = referenceURL,
                  referencePlayer?.prepare(id: id, url: url, owner: owner) == true else {
                error = referencePlayer?.error ?? "找不到附加音频。"
                pauseFollowing()
                return
            }
            if let player = referencePlayer, player.currentTime >= player.duration { follower.reset() }
            referencePlayer?.play()
            guard referencePlayer?.isPlaying == true else { pauseFollowing(); return }
        } else {
            // Silent performance must also stop any existing backing/lesson.
            audio.stop()
            referencePlayer?.pause()
        }
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        if follower.targets.isEmpty || follower.isFinished { follower.start(score: score, voice: voice, at: now) }
        else { follower.resume(at: now) }
        clearSelection()
    }

    func pauseFollowing() {
        if Self.activePerformer === self { Self.activePerformer = nil }
        if follower.isRunning { follower.pause() }
        if captureWasStarted, let audio {
            captureWasStarted = false
            if audio.source == .input {
                audio.stopCapture()
                if let previousCaptureSource { audio.source = previousCaptureSource }
            }
            previousCaptureSource = nil
        }
    }

    func resetFollowing() {
        let wasRunning = transportIsPlaying
        follower.reset()
        if wasRunning { follower.start(score: score, voice: voice, at: AVAudioTime.seconds(forHostTime: mach_absolute_time())) }
    }

    func consumePerformance(_ frame: PitchFrame) {
        guard isPerformanceMode, audio?.source == .input, audio?.isCapturing == true else { return }
        if audioSource == .reference {
            guard referencePlayer?.ownerID == owner, referencePlayer?.isPlaying == true else { return }
        } else if audio?.isPlaying == true || referencePlayer?.isPlaying == true {
            pauseFollowing()
            return
        }
        follower.consume(PitchObservation(timestamp: frame.timestamp, frequency: frame.frequency,
                                          cents: frame.cents, confidence: frame.confidence, rms: frame.rms,
                                          isStable: frame.isStable, onsetTimestamp: frame.onsetTimestamp))
    }

    func stopTransport() {
        stopOwnedPlayback()
        if isPerformanceMode {
            follower.reset()
            if referencePlayer?.ownerID == owner { referencePlayer?.seek(0) }
        }
    }

    func restartTransport() {
        if isPerformanceMode {
            resetFollowing()
            if audioSource == .reference, referencePlayer?.ownerID == owner { referencePlayer?.seek(0) }
        } else { locatePlayback(at: 0) }
    }
}
