import Foundation

/// All timestamps use the same monotonic host clock. onsetTimestamp is the measured attack,
/// never the later time at which a pitch algorithm finished analyzing its window.
public struct PitchObservation: Equatable, Sendable {
    public var timestamp: Double
    public var frequency: Double
    public var cents: Double
    public var confidence: Double
    public var rms: Double
    public var isStable: Bool
    public var onsetTimestamp: Double?
    public init(timestamp: Double, frequency: Double, cents: Double = 0, confidence: Double, rms: Double, isStable: Bool = true, onsetTimestamp: Double? = nil) {
        self.timestamp = timestamp; self.frequency = frequency; self.cents = cents; self.confidence = confidence; self.rms = rms; self.isStable = isStable; self.onsetTimestamp = onsetTimestamp
    }
    public var midi: Double { MusicTheory.midi(frequency: frequency) }
}

public enum PracticeMode: String, CaseIterable, Identifiable, Sendable {
    case waitForCorrect, timed
    public var id: String { rawValue }
    public var title: String { self == .waitForCorrect ? "弹对再前进" : "按节拍跟练" }
}

public struct PracticeConfiguration: Equatable, Sendable {
    public var centsTolerance: Double
    public var stableDuration: Double
    public var onsetTolerance: Double
    public var inputLatency: Double
    public var minimumConfidence: Double
    public var minimumRMS: Double
    /// A grace period for receiving analysis of an already timestamped attack.
    public var analysisGrace: Double
    public init(centsTolerance: Double = 25, stableDuration: Double = 0.120, onsetTolerance: Double = 0.150, inputLatency: Double = 0, minimumConfidence: Double = 0.75, minimumRMS: Double = 0.002, analysisGrace: Double = 0.350) {
        self.centsTolerance = centsTolerance; self.stableDuration = stableDuration; self.onsetTolerance = onsetTolerance; self.inputLatency = inputLatency
        self.minimumConfidence = minimumConfidence; self.minimumRMS = minimumRMS; self.analysisGrace = analysisGrace
    }
}

public struct PracticeTarget: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var startTick: Int
    public var endTick: Int
    public var midi: Int?
    public var noteIDs: [UUID]
    public var requiresOnset: Bool
    public var skipReason: String?
    public var title: String { midi.map { MusicTheory.noteName(midi: $0) } ?? "跳过评分" }
    public init(id: UUID = UUID(), startTick: Int, endTick: Int, midi: Int?, noteIDs: [UUID] = [], requiresOnset: Bool = false, skipReason: String? = nil) {
        self.id = id; self.startTick = startTick; self.endTick = endTick; self.midi = midi; self.noteIDs = noteIDs; self.requiresOnset = requiresOnset; self.skipReason = skipReason
    }
    public static func from(score: GuitarScore, voice: ScoreVoice) -> [PracticeTarget] {
        guard !ScoreValidator.validate(score).contains(where: { $0.severity == .error }) else { return [] }
        let scheduled = ScoreScheduler.notes(score).filter { $0.voice == voice }
        let continuations = Set(scheduled.flatMap(\.continuationIDs))
        var result: [PracticeTarget] = []
        var previousMIDI: Int?
        for (measureIndex, measure) in score.measures.enumerated() {
            for event in measure.events(for: voice).sorted(by: { $0.startTick < $1.startTick }) where !event.notes.isEmpty {
                if event.notes.allSatisfy({ continuations.contains($0.id) }) { continue }
                let note = event.notes.first!
                let midi = (1...6).contains(note.string) && score.tuning.count == 6 ? score.midi(for: note) : nil
                let start = measureIndex * score.timeSignature.ticks + event.startTick
                let end = scheduled.first(where: { $0.id == note.id })?.endTick ?? start + event.rhythm.ticks
                let skip: String?
                if event.notes.count > 1 { skip = "同声部和弦不进行单音评分" }
                else if note.technique == .deadNote { skip = "死音没有固定音高" }
                else if [.hammerOn,.pullOff,.slide,.bendHalf,.bendFull,.vibrato].contains(note.technique) { skip = "连续变音技巧不进行单音评分" }
                else { skip = nil }
                result.append(PracticeTarget(id: event.id, startTick: start, endTick: end, midi: midi, noteIDs: event.notes.map(\.id), requiresOnset: midi == previousMIDI, skipReason: skip))
                previousMIDI = midi
            }
        }
        return result
    }
}

public enum PracticeOutcome: String, Equatable, Sendable { case correct, early, late, wrongPitch, missed, skipped, manual
    public var title: String {
        switch self { case .correct: return "正确"; case .early: return "抢拍"; case .late: return "拖拍"; case .wrongPitch: return "音高错误"; case .missed: return "漏音"; case .skipped: return "跳过"; case .manual: return "手动继续" }
    }
}
public struct PracticeResult: Identifiable, Equatable, Sendable {
    public var id: UUID { target.id }
    public var target: PracticeTarget
    public var outcome: PracticeOutcome
    public var centsError: Double?
    public var timingOffset: Double?
    public var onsetTimestamp: Double?
    public var assessedAt: Double
    public var reason: String?
    public var timingDescription: String {
        guard let timingOffset else { return "—" }
        let ms = Int((timingOffset * 1000).rounded())
        return abs(ms) < 20 ? "拍点准确" : "\(ms < 0 ? "抢拍" : "拖拍") \(abs(ms)) ms"
    }
}

public struct PracticeSummary: Equatable, Sendable {
    public var assessed: Int
    public var correct: Int
    public var missed: Int
    public var skipped: Int
    public var meanAbsoluteTimingMS: Double?
    public var accuracy: Double { assessed == 0 ? 0 : Double(correct) / Double(assessed) }
}

/// Deterministic practice state machine, independent of audio capture and UI scheduling.
public struct PracticeEngine: Sendable {
    public var configuration: PracticeConfiguration
    public private(set) var targets: [PracticeTarget] = []
    public private(set) var mode: PracticeMode = .waitForCorrect
    public private(set) var index = 0
    public private(set) var results: [PracticeResult] = []
    public private(set) var isRunning = false
    public private(set) var isDemonstrating = false
    public private(set) var status = "选择声部后开始练习"
    private var startedAt: Double = 0
    private var bpm: Double = 80
    private var stableSince: Double?
    private var stabilityOnset: Double?
    private var previousFrame: Double?
    private var consumedOnset: Double = -.infinity
    private var targetBegan: Double = 0
    private var demonstrationBegan: Double?
    private var provisional: PracticeResult?
    private var resumedNeedsAttack = false
    public init(configuration: PracticeConfiguration = PracticeConfiguration()) { self.configuration = configuration }
    public var currentTarget: PracticeTarget? { targets.indices.contains(index) ? targets[index] : nil }
    public var isFinished: Bool { !targets.isEmpty && index >= targets.count }
    public var progress: Double { targets.isEmpty ? 0 : Double(index) / Double(targets.count) }
    public var summary: PracticeSummary {
        let scored = results.filter { ![.skipped,.manual].contains($0.outcome) }
        let timings = scored.compactMap(\.timingOffset).map { abs($0) * 1000 }
        return PracticeSummary(assessed: scored.count, correct: scored.filter { $0.outcome == .correct }.count,
            missed: scored.filter { $0.outcome == .missed }.count, skipped: results.count - scored.count,
            meanAbsoluteTimingMS: timings.isEmpty ? nil : timings.reduce(0,+) / Double(timings.count))
    }
    public mutating func start(targets: [PracticeTarget], mode: PracticeMode, at timestamp: Double, bpm: Double = 80) {
        self.targets = targets; self.mode = mode; startedAt = timestamp; self.bpm = bpm.isFinite && bpm > 0 ? bpm : 80
        index = 0; results = []; stableSince = nil; stabilityOnset = nil; previousFrame = nil; consumedOnset = -.infinity
        targetBegan = timestamp; provisional = nil; isRunning = !targets.isEmpty; isDemonstrating = false; demonstrationBegan = nil; resumedNeedsAttack = false
        refreshStatus()
    }
    public mutating func stop() { isRunning = false; stableSince = nil; stabilityOnset = nil; status = "练习已停止" }
    /// Used by learning and document panels when their input score is recomputed.
    @discardableResult public mutating func stopIfScoreChanged(from previous: GuitarScore, to current: GuitarScore) -> Bool {
        guard !previous.hasSameContent(as: current) else { return false }
        stop(); return true
    }
    public mutating func synchronizeTimeline(startedAt timestamp: Double, bpm: Double? = nil) {
        startedAt = timestamp; stableSince = nil; stabilityOnset = nil; previousFrame = nil; provisional = nil
        if let bpm, bpm.isFinite && bpm > 0 { self.bpm = bpm }
    }
    public mutating func setDemonstrating(_ enabled: Bool, at timestamp: Double) {
        guard enabled != isDemonstrating else { return }
        if enabled { demonstrationBegan = timestamp; status = "示范试听中，暂停判定" }
        else {
            if let began = demonstrationBegan { startedAt += timestamp - began }
            demonstrationBegan = nil; targetBegan = timestamp; consumedOnset = timestamp
            resumedNeedsAttack = true
        }
        isDemonstrating = enabled; stableSince = nil; stabilityOnset = nil; previousFrame = nil
        if !enabled { refreshStatus() }
    }
    public func expectedTimestamp(for target: PracticeTarget) -> Double { startedAt + Double(target.startTick) / 960 * 60 / bpm }
    public mutating func manualAdvance(at timestamp: Double) {
        guard isRunning, !isDemonstrating, let target = currentTarget else { return }
        finish(PracticeResult(target: target, outcome: target.skipReason == nil ? .manual : .skipped,
            centsError: nil, timingOffset: nil, onsetTimestamp: nil, assessedAt: timestamp, reason: target.skipReason))
    }
    public mutating func update(at timestamp: Double) {
        guard isRunning, !isDemonstrating, mode == .timed else { return }
        while let target = currentTarget {
            let expected = expectedTimestamp(for: target)
            if target.skipReason != nil, timestamp >= expected {
                finish(PracticeResult(target: target, outcome: .skipped, centsError: nil, timingOffset: nil, onsetTimestamp: nil, assessedAt: timestamp, reason: target.skipReason))
            } else if timestamp > expected + configuration.onsetTolerance + configuration.analysisGrace {
                finish(provisional ?? PracticeResult(target: target, outcome: .missed, centsError: nil, timingOffset: nil, onsetTimestamp: nil, assessedAt: timestamp, reason: "未检测到容差范围内的新起音"))
            } else { break }
        }
    }
    public mutating func consume(_ observation: PitchObservation) {
        guard isRunning, !isDemonstrating, observation.timestamp.isFinite else { return }
        if mode == .timed, let measuredOnset = observation.onsetTimestamp, measuredOnset > consumedOnset {
            let onset = measuredOnset - configuration.inputLatency
            // A measured later attack is evidence that an earlier note was missed. Do not let
            // the analysis grace for that missed note block all subsequent short notes.
            while let target = currentTarget, onset > expectedTimestamp(for: target) + configuration.onsetTolerance {
                guard index + 1 < targets.count else { break }
                let next = targets[index + 1]
                guard abs(onset - expectedTimestamp(for: next)) < abs(onset - expectedTimestamp(for: target)) else { break }
                let outcome: PracticeOutcome = target.skipReason == nil ? .missed : .skipped
                finish(provisional ?? PracticeResult(target: target, outcome: outcome, centsError: nil, timingOffset: nil,
                    onsetTimestamp: nil, assessedAt: observation.timestamp, reason: target.skipReason ?? "下一音已起音，前一音未在容差内出现"))
            }
        }
        guard let target = currentTarget else { return }
        guard target.skipReason == nil, let midi = target.midi else { return }
        let reliable = observation.frequency.isFinite && observation.frequency > 0 && observation.confidence >= configuration.minimumConfidence && observation.rms >= configuration.minimumRMS
        let error = reliable ? (observation.midi - Double(midi)) * 100 : Double.infinity
        let correct = reliable && abs(error) <= configuration.centsTolerance
        if mode == .waitForCorrect {
            let requiresAttack = target.requiresOnset || resumedNeedsAttack
            // Pitch timestamps mark the analysis window's center. A newly detected attack
            // can be later in that window, so older pitch evidence cannot validate it yet.
            let freshAttack = observation.onsetTimestamp.map {
                $0.isFinite && $0 > consumedOnset && $0 >= targetBegan - 0.100 && $0 <= observation.timestamp
            } ?? false
            if !correct || (requiresAttack && !freshAttack) {
                stableSince = nil; stabilityOnset = nil; previousFrame = observation.timestamp
                status = requiresAttack && correct ? "请重新拨弦后继续" : "目标 \(target.title) · 稳定 \(Int(configuration.stableDuration * 1000)) ms"
                return
            }
            if requiresAttack && stabilityOnset != observation.onsetTimestamp {
                stableSince = nil; stabilityOnset = observation.onsetTimestamp
            }
            // Input taps can deliver at 100 ms intervals. Match PitchTracker's 120 ms
            // continuity limit so normal timestamp jitter is not mistaken for a lost window.
            if let previousFrame, observation.timestamp - previousFrame >= 0.120 || observation.timestamp < previousFrame { stableSince = nil }
            if stableSince == nil { stableSince = observation.timestamp }
            previousFrame = observation.timestamp
            if observation.timestamp - stableSince! >= configuration.stableDuration - 0.0000001 {
                finish(PracticeResult(target: target, outcome: .correct, centsError: error, timingOffset: nil, onsetTimestamp: observation.onsetTimestamp, assessedAt: observation.timestamp, reason: nil))
            }
        } else {
            guard let measuredOnset = observation.onsetTimestamp, measuredOnset.isFinite, measuredOnset > consumedOnset else { return }
            let onset = measuredOnset - configuration.inputLatency
            let offset = onset - expectedTimestamp(for: target)
            guard abs(offset) <= max(0.5, configuration.onsetTolerance * 3) else { return }
            let outcome: PracticeOutcome = !correct ? .wrongPitch : offset < -configuration.onsetTolerance ? .early : offset > configuration.onsetTolerance ? .late : .correct
            let result = PracticeResult(target: target, outcome: outcome, centsError: reliable ? error : nil, timingOffset: offset, onsetTimestamp: measuredOnset, assessedAt: observation.timestamp, reason: nil)
            if outcome == .correct { finish(result) }
            else if reliable && (provisional == nil || abs(offset) < abs(provisional!.timingOffset ?? .infinity) || (correct && provisional!.outcome == .wrongPitch)) { provisional = result }
        }
    }
    private mutating func finish(_ result: PracticeResult) {
        results.append(result); index += 1; stableSince = nil; stabilityOnset = nil; previousFrame = nil; provisional = nil; targetBegan = result.assessedAt; resumedNeedsAttack = false
        if let onset = result.onsetTimestamp { consumedOnset = max(consumedOnset, onset) }
        if index >= targets.count { isRunning = false }
        refreshStatus()
    }
    private mutating func refreshStatus() {
        if isFinished { status = "练习完成 · \(summary.correct)/\(summary.assessed) 正确" }
        else if let target = currentTarget { status = target.skipReason.map { "\($0) · \(mode == .waitForCorrect ? "请手动继续" : "按时间继续")" } ?? "目标 \(target.title)" }
        else { status = "此声部没有可练习的音符" }
    }
}

public enum InputLatencyCalibration {
    /// Median attack difference rejects accidental extra plucks. A positive value means capture is late.
    public static func estimate(expected: [Double], detected: [Double]) -> Double? {
        guard expected.count == detected.count, expected.count >= 3 else { return nil }
        let differences = zip(expected, detected).map { $1 - $0 }.filter { $0.isFinite && abs($0) <= 1 }.sorted()
        guard differences.count >= 3 else { return nil }
        let middle = differences.count / 2
        return differences.count % 2 == 0 ? (differences[middle - 1] + differences[middle]) / 2 : differences[middle]
    }
}
