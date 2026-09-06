import Foundation

public struct ScoreFollowerConfiguration: Equatable, Sendable {
    public var centsTolerance: Double
    public var stableDuration: Double
    public var minimumConfidence: Double
    public var minimumRMS: Double
    /// Recovery can skip this many playable targets, and needs the following note as confirmation.
    public var maximumSkippedNotes: Int
    public var recoveryWindow: Double

    public init(centsTolerance: Double = 35, stableDuration: Double = 0.120,
                minimumConfidence: Double = 0.75, minimumRMS: Double = 0.002,
                maximumSkippedNotes: Int = 3, recoveryWindow: Double = 8) {
        self.centsTolerance = centsTolerance; self.stableDuration = stableDuration
        self.minimumConfidence = minimumConfidence; self.minimumRMS = minimumRMS
        self.maximumSkippedNotes = maximumSkippedNotes; self.recoveryWindow = recoveryWindow
    }
}

/// Follows the selected voice from microphone evidence, without an audio or metronome clock.
/// Position remains at the last confirmed note. Rests and unsupported polyphonic/technique
/// events have no pitch evidence, so they are crossed only when a later supported note is played.
public struct ScoreFollower: Sendable {
    public var configuration: ScoreFollowerConfiguration
    public private(set) var targets: [PracticeTarget] = []
    public private(set) var nextIndex = 0
    public private(set) var matchedTarget: PracticeTarget?
    public private(set) var isRunning = false
    public private(set) var status = "开始演奏后，曲谱将跟随输入音符"
    public private(set) var unsupportedTargetCount = 0

    private var activeFrom = Double.infinity
    private var previousFrame: Double?
    private var stableSince: Double?
    private var stableMIDI: Int?
    private var stabilityOnset: Double?
    private var consumedOnset = -Double.infinity
    private var previousPitch: Int?
    private var needsFreshAttack = true
    private var recoveryCandidates: [Int] = []
    private var recoveryBegan: Double?

    public init(configuration: ScoreFollowerConfiguration = ScoreFollowerConfiguration()) {
        self.configuration = configuration
    }

    public var nextTarget: PracticeTarget? { targets.indices.contains(nextIndex) ? targets[nextIndex] : nil }
    public var currentTick: Int { matchedTarget?.startTick ?? 0 }
    public var matchedNoteIDs: [UUID] { matchedTarget?.noteIDs ?? [] }
    public var isFinished: Bool { !targets.isEmpty && nextIndex >= targets.count }

    public mutating func start(score: GuitarScore, voice: ScoreVoice, at timestamp: Double) {
        start(targets: PracticeTarget.from(score: score, voice: voice), at: timestamp)
    }

    public mutating func start(targets: [PracticeTarget], at timestamp: Double) {
        reset()
        self.targets = targets.filter {
            $0.skipReason == nil && $0.midi.map { (0...127).contains($0) } == true
                && $0.startTick >= 0 && $0.endTick > $0.startTick
        }.sorted { $0.startTick < $1.startTick }
        unsupportedTargetCount = targets.count - self.targets.count
        guard timestamp.isFinite else { status = "无法开始音符跟随"; return }
        activeFrom = timestamp
        isRunning = !self.targets.isEmpty
        refreshStatus()
    }

    public mutating func pause() {
        isRunning = false
        clearEvidence()
        if !targets.isEmpty && !isFinished { status = "跟随已暂停" }
    }

    public mutating func resume(at timestamp: Double) {
        guard timestamp.isFinite, !targets.isEmpty, !isFinished else { return }
        activeFrom = timestamp
        clearEvidence()
        isRunning = true
        refreshStatus()
    }

    public mutating func reset() {
        targets = []; nextIndex = 0; matchedTarget = nil; unsupportedTargetCount = 0
        isRunning = false; activeFrom = .infinity; consumedOnset = -.infinity
        previousPitch = nil
        clearEvidence()
        status = "开始演奏后，曲谱将跟随输入音符"
    }

    public mutating func consume(_ observation: PitchObservation) {
        guard isRunning, observation.timestamp.isFinite, observation.timestamp >= activeFrom else { return }
        // A replayed or out-of-order capture frame must not contribute extra stability.
        if let previousFrame, observation.timestamp <= previousFrame { return }
        let hasGap = previousFrame.map { observation.timestamp - $0 >= 0.120 } ?? false
        previousFrame = observation.timestamp
        guard observation.frequency.isFinite, observation.frequency > 0,
              observation.confidence.isFinite, observation.confidence >= configuration.minimumConfidence,
              observation.rms.isFinite, observation.rms >= configuration.minimumRMS,
              observation.midi.isFinite, (0...127).contains(observation.midi.rounded()),
              abs(observation.midi - observation.midi.rounded()) * 100 <= configuration.centsTolerance else {
            clearStability()
            refreshStatus()
            return
        }
        let midi = Int(observation.midi.rounded())
        let freshOnset = observation.onsetTimestamp.flatMap { onset -> Double? in
            guard onset.isFinite, onset >= activeFrom, onset <= observation.timestamp, onset > consumedOnset else { return nil }
            return onset
        }
        // First input after start/resume must be newly played. Repeated notes also require
        // a new measured attack: a sustained tone cannot walk through repeated score notes.
        if (needsFreshAttack || previousPitch == midi) && freshOnset == nil {
            clearStability()
            status = needsFreshAttack || nextTarget?.midi == midi ? "请拨弦，开始跟随下一音" : waitingStatus
            return
        }
        if hasGap || stableMIDI != midi || stabilityOnset != freshOnset {
            clearStability()
        }
        if stableSince == nil {
            stableSince = observation.timestamp; stableMIDI = midi; stabilityOnset = freshOnset
        }
        // Measure one continuous pitch window here. PitchObservation.isStable is a display
        // hint from the analyzer; waiting for it first would add a second 120 ms delay.
        guard observation.timestamp - stableSince! >= max(0, configuration.stableDuration) - 0.0000001 else { return }
        previousPitch = midi; needsFreshAttack = false
        if let freshOnset { consumedOnset = freshOnset }
        clearStability()
        acceptPitch(midi, at: observation.timestamp)
    }

    private mutating func acceptPitch(_ midi: Int, at timestamp: Double) {
        if nextTarget?.midi == midi {
            confirm(nextIndex)
            return
        }
        // One later pitch is only a hypothesis. Two independently played consecutive
        // targets must agree before recovering past a missed note. Prefer the nearest path.
        if let recoveryBegan, timestamp - recoveryBegan <= configuration.recoveryWindow,
           let candidate = recoveryCandidates.first(where: {
               targets.indices.contains($0 + 1) && targets[$0 + 1].midi == midi
           }) {
            confirm(candidate + 1)
            return
        }
        recoveryCandidates = []
        let available = targets.count - nextIndex - 1
        let lookahead = min(max(0, configuration.maximumSkippedNotes), max(0, available))
        if lookahead > 0 {
            recoveryCandidates = (1...lookahead).map { nextIndex + $0 }.filter {
                targets[$0].midi == midi && $0 + 1 < targets.count
            }
        }
        recoveryBegan = recoveryCandidates.isEmpty ? nil : timestamp
        status = recoveryCandidates.isEmpty ? waitingStatus : "正在确认演奏位置 · 继续弹下一音"
    }

    private mutating func confirm(_ index: Int) {
        matchedTarget = targets[index]
        nextIndex = index + 1
        recoveryCandidates = []; recoveryBegan = nil
        if isFinished { isRunning = false }
        refreshStatus()
    }

    private var waitingStatus: String {
        nextTarget.map { "音符跟随 · 等待 \($0.title)" } ?? "此声部没有可跟随的单音"
    }

    private mutating func refreshStatus() {
        status = isFinished ? "已跟随至最后一个可识别单音" : waitingStatus
    }

    private mutating func clearStability() {
        stableSince = nil; stableMIDI = nil; stabilityOnset = nil
    }

    private mutating func clearEvidence() {
        clearStability(); previousFrame = nil; needsFreshAttack = true
        recoveryCandidates = []; recoveryBegan = nil
    }
}
