import Foundation

public enum TunerMode: String, CaseIterable, Identifiable, Sendable {
    case chromatic, automaticString, lockedString
    public var id: String { rawValue }
    public var title: String {
        switch self { case .chromatic: return "色度"; case .automaticString: return "自动目标弦"; case .lockedString: return "锁定弦" }
    }
}

public enum TunerPreset: String, CaseIterable, Identifiable, Sendable {
    case standard, dropD, dadgad, halfStepDown, openG, openD, openE
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .standard: return "标准调弦"
        case .dropD: return "Drop D"
        case .dadgad: return "DADGAD"
        case .halfStepDown: return "降半音"
        case .openG: return "开放 G"
        case .openD: return "开放 D"
        case .openE: return "开放 E"
        }
    }
    /// String order is always 1 (thinnest) through 6 (thickest), as in GuitarScore.
    public var midiNotes: [Int] {
        switch self {
        case .standard: return [64, 59, 55, 50, 45, 40]
        case .dropD: return [64, 59, 55, 50, 45, 38]
        case .dadgad: return [62, 57, 55, 50, 45, 38]
        case .halfStepDown: return [63, 58, 54, 49, 44, 39]
        case .openG: return [62, 59, 55, 50, 43, 38]
        case .openD: return [62, 57, 54, 50, 45, 38]
        case .openE: return [64, 59, 56, 52, 47, 40]
        }
    }
    public func noteName(string: Int) -> String {
        guard (1...6).contains(string) else { return "—" }
        let names: [String]
        switch self {
        case .halfStepDown: names = ["E♭4", "B♭3", "G♭3", "D♭3", "A♭2", "E♭2"]
        case .openE: names = ["E4", "B3", "G♯3", "E3", "B2", "E2"]
        default: return MusicTheory.noteName(midi: midiNotes[string - 1])
        }
        return names[string - 1]
    }
    public var lowToHighNames: String { (1...6).reversed().map { noteName(string: $0) }.joined(separator: "  ") }
}

public struct TunerConfiguration: Equatable, Sendable {
    public var mode: TunerMode
    public var preset: TunerPreset
    public var lockedString: Int
    public var referenceA4: Double
    public init(mode: TunerMode = .automaticString, preset: TunerPreset = .standard, lockedString: Int = 6, referenceA4: Double = 440) {
        self.mode = mode; self.preset = preset
        self.lockedString = min(6, max(1, lockedString))
        self.referenceA4 = Self.validReference(referenceA4)
    }
    public static func validReference(_ value: Double) -> Double { value.isFinite ? min(480, max(400, value)) : 440 }
    public func stringTarget(_ string: Int) -> TunerTarget? {
        guard (1...6).contains(string) else { return nil }
        let midi = preset.midiNotes[string - 1]
        return TunerTarget(midi: midi, string: string, name: preset.noteName(string: string), frequency: MusicTheory.frequency(midi: Double(midi), a4: Self.validReference(referenceA4)))
    }
}

/// This is a selected/matched tuning target, never a claim about the physical string played.
public struct TunerTarget: Equatable, Sendable {
    public let midi: Int
    public let string: Int?
    public let name: String
    public let frequency: Double
    public var identity: String { "\(midi)-\(string ?? 0)" }
}

public struct TunerReading: Equatable, Sendable {
    public let timestamp: Double
    public let frequency: Double
    public let detectedMIDI: Int
    public let target: TunerTarget?
    public let cents: Double?
    public let confidence: Double
    public let stableDuration: Double
    public let spreadCents: Double?
    public var isStable: Bool { stableDuration >= 0.18 && (spreadCents ?? .infinity) <= 10 }
    public var isInTune: Bool { isStable && abs(cents ?? .infinity) <= 5 }
}

public struct TunerHistoryPoint: Equatable, Identifiable, Sendable {
    public let timestamp: Double
    public let cents: Double
    public let frequency: Double
    public let targetID: String
    public var id: Double { timestamp }
}

/// Offline tuning arithmetic. Input timestamps and `now` must use the same monotonic clock.
/// PitchObservation.cents, .midi and .isStable are deliberately not used: reference pitch,
/// target distance and stability are recomputed from measured frequency.
public struct TunerEngine: Sendable {
    public private(set) var configuration: TunerConfiguration
    public private(set) var reading: TunerReading?
    public private(set) var history: [TunerHistoryPoint] = []
    public static let maximumFrameAge = 0.45
    public static let historyDuration = 8.0
    private var lastAcceptedTimestamp: Double?
    private var continuous: [TunerHistoryPoint] = []

    public init(configuration: TunerConfiguration = TunerConfiguration()) { self.configuration = configuration }
    public mutating func configure(_ value: TunerConfiguration) {
        guard value != configuration else { return }
        configuration = value; reset()
    }
    public mutating func reset() {
        reading = nil; history.removeAll(keepingCapacity: true)
        continuous.removeAll(keepingCapacity: true); lastAcceptedTimestamp = nil
    }
    public mutating func advance(now: Double, captureActive: Bool) {
        guard captureActive, now.isFinite else { reset(); return }
        history.removeAll { now - $0.timestamp > Self.historyDuration || $0.timestamp > now + 0.05 }
        if let reading, now - reading.timestamp > Self.maximumFrameAge {
            self.reading = nil; continuous.removeAll(keepingCapacity: true)
        }
    }
    public mutating func receive(_ observation: PitchObservation?, now: Double, captureActive: Bool) {
        advance(now: now, captureActive: captureActive)
        guard captureActive, now.isFinite else { return }
        guard let observation else { reading = nil; continuous.removeAll(keepingCapacity: true); return }
        guard observation.timestamp.isFinite, observation.timestamp <= now + 0.05,
              now - observation.timestamp <= Self.maximumFrameAge else { return }
        // A queued, repeated or out-of-order frame must not extend a note's stability.
        guard lastAcceptedTimestamp.map({ observation.timestamp > $0 }) ?? true else { return }
        lastAcceptedTimestamp = observation.timestamp
        guard observation.frequency.isFinite, (20...2000).contains(observation.frequency),
              observation.confidence.isFinite, observation.confidence >= 0.8,
              observation.rms.isFinite, observation.rms >= 0.004 else {
            reading = nil; continuous.removeAll(keepingCapacity: true); return
        }
        let midi = Int(MusicTheory.midi(frequency: observation.frequency, a4: TunerConfiguration.validReference(configuration.referenceA4)).rounded())
        let target = target(frequency: observation.frequency, nearestMIDI: midi)
        let cents = target.map { 1200 * log2(observation.frequency / $0.frequency) }
        if let target, let cents {
            let point = TunerHistoryPoint(timestamp: observation.timestamp, cents: cents, frequency: observation.frequency, targetID: target.identity)
            if let previous = continuous.last,
               previous.targetID != target.identity || observation.timestamp - previous.timestamp > 0.15 {
                continuous.removeAll(keepingCapacity: true)
            }
            continuous.append(point)
            continuous.removeAll { observation.timestamp - $0.timestamp > 0.4 }
            history.append(point)
            // Bound storage even for an unusually high input cadence.
            if history.count > 640 { history.removeFirst(history.count - 640) }
        } else { continuous.removeAll(keepingCapacity: true) }
        let frequencies = continuous.map(\.frequency)
        let spread: Double? = frequencies.count >= 4 ? 1200 * log2(frequencies.max()! / frequencies.min()!) : nil
        let duration = continuous.count >= 4 ? observation.timestamp - continuous[0].timestamp : 0
        reading = TunerReading(timestamp: observation.timestamp, frequency: observation.frequency, detectedMIDI: midi,
                              target: target, cents: cents, confidence: min(1, observation.confidence),
                              stableDuration: duration, spreadCents: spread)
    }

    private func target(frequency: Double, nearestMIDI: Int) -> TunerTarget? {
        switch configuration.mode {
        case .chromatic:
            return TunerTarget(midi: nearestMIDI, string: nil, name: MusicTheory.noteName(midi: nearestMIDI),
                               frequency: MusicTheory.frequency(midi: Double(nearestMIDI), a4: TunerConfiguration.validReference(configuration.referenceA4)))
        case .lockedString: return configuration.stringTarget(configuration.lockedString)
        case .automaticString:
            let targets = (1...6).compactMap { configuration.stringTarget($0) }
            guard let closest = targets.min(by: { abs(log2(frequency / $0.frequency)) < abs(log2(frequency / $1.frequency)) }),
                  abs(1200 * log2(frequency / closest.frequency)) <= 250 else { return nil }
            // Small hysteresis avoids flicker at the midpoint between adjacent targets.
            if let previous = reading?.target, let previousString = previous.string,
               let retained = configuration.stringTarget(previousString) {
                let oldDistance = abs(1200 * log2(frequency / retained.frequency))
                let newDistance = abs(1200 * log2(frequency / closest.frequency))
                if oldDistance <= 250 && oldDistance <= newDistance + 15 { return retained }
            }
            return closest
        }
    }
}
