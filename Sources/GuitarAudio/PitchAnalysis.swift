import Foundation
import Synchronization

public struct PitchFrame: Equatable, Sendable {
    /// Monotonic host time of the analysis window centre; never UI delivery time.
    public var timestamp: Double
    public var frequency: Double
    public var midi: Int
    public var cents: Double
    public var confidence: Double
    public var rms: Double
    public var isStable: Bool
    /// Independently measured attack time, not the completion of the YIN window.
    public var onsetTimestamp: Double?
    public init(timestamp: Double, frequency: Double, midi: Int, cents: Double, confidence: Double, rms: Double, isStable: Bool = false, onsetTimestamp: Double? = nil) {
        self.timestamp = timestamp; self.frequency = frequency; self.midi = midi; self.cents = cents
        self.confidence = confidence; self.rms = rms; self.isStable = isStable; self.onsetTimestamp = onsetTimestamp
    }
    public var octave: Int { midi / 12 - 1 }
    public var noteName: String { ["C","C♯","D","E♭","E","F","F♯","G","A♭","A","B♭","B"][((midi % 12) + 12) % 12] }
}

public struct YINDetector {
    public var threshold = 0.16
    public var minimumFrequency = 65.0
    public var maximumFrequency = 1500.0
    public var referenceA = 440.0
    public init() {}
    public func detect(_ samples: [Float], sampleRate: Double, timestamp: Double = 0) -> PitchFrame? {
        guard samples.count >= 256, sampleRate > 0 else { return nil }
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        let energy = samples.reduce(0.0) { $0 + pow(Double($1) - mean, 2) }
        let rms = sqrt(energy / Double(samples.count))
        guard rms > 0.004 else { return nil }
        let maxLag = min(samples.count / 2 - 1, Int(sampleRate / minimumFrequency))
        let minLag = max(2, Int(sampleRate / maximumFrequency))
        guard maxLag > minLag else { return nil }
        var difference = [Double](repeating: 0, count: maxLag + 1)
        let window = samples.count - maxLag
        for lag in 1...maxLag {
            var value = 0.0
            for j in 0..<window {
                let delta = Double(samples[j]) - Double(samples[j + lag])
                value += delta * delta
            }
            difference[lag] = value
        }
        var total = 0.0
        difference[0] = 1
        for lag in 1...maxLag {
            total += difference[lag]
            difference[lag] = total > 1e-16 ? difference[lag] * Double(lag) / total : 1
        }
        var candidate: Int?
        var lag = minLag
        while lag < maxLag {
            if difference[lag] < threshold {
                while lag + 1 <= maxLag && difference[lag + 1] < difference[lag] { lag += 1 }
                // A plucked string can have small neighbouring valleys before its true period.
                // Search this valley cluster, never as far as a second octave candidate.
                let upper = min(maxLag, lag + max(3, Int(Double(lag) * 0.12)))
                candidate = (lag...upper).min { difference[$0] < difference[$1] }
                break
            }
            lag += 1
        }
        guard let period = candidate else { return nil }
        let confidence = 1 - difference[period]
        guard confidence > 0.80 else { return nil }
        var refined = Double(period)
        if period > 0 && period < maxLag {
            let left = difference[period - 1], centre = difference[period], right = difference[period + 1]
            let denominator = 2 * (2 * centre - right - left)
            if abs(denominator) > 1e-10 { refined += (right - left) / denominator }
        }
        let frequency = sampleRate / refined
        let exactMidi = 69 + 12 * log2(frequency / referenceA)
        let midi = Int(exactMidi.rounded())
        return PitchFrame(timestamp: timestamp, frequency: frequency, midi: midi, cents: (exactMidi - Double(midi)) * 100, confidence: confidence, rms: rms)
    }
}

/// Continuous energy detector; attack timestamps stay independent of pitch-window latency.
public struct OnsetDetector {
    private var energy = 0.0
    private var background = 0.0
    private var previousSample = 0.0
    private var differenceEnergy = 0.0
    private var differenceBackground = 0.0
    private var lastOnset = -Double.infinity
    public private(set) var onsetTimestamp: Double?
    public init() {}
    public mutating func process(_ samples: ArraySlice<Float>, sampleRate: Double, startTime: Double) -> Double? {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate > 0, startTime.isFinite else { return nil }
        // Smooth power over time, not independently per callback fragment. A low E's
        // harmonics have periodic sharp peaks; a short block (or its 58-sample tail
        // at 44.1 kHz) must not turn each peak into a fresh pick attack.
        let fast = 1 - exp(-1 / (sampleRate * 0.006))
        let slow = 1 - exp(-1 / (sampleRate * 0.032))
        let brightnessSlow = 1 - exp(-1 / (sampleRate * 0.065))
        var result: Double?
        for (offset, sample) in samples.enumerated() {
            let value = Double(sample)
            let delta = value - previousSample
            previousSample = value
            energy += fast * (value * value - energy)
            differenceEnergy += fast * (delta * delta - differenceEnergy)
            let energyRise = energy > max(0.009 * 0.009, background * 1.7 * 1.7)
            // A real re-pluck replenishes high harmonics while the fundamental rings.
            let brightnessRise = energy > 0.007 * 0.007 && differenceEnergy > max(0.0025 * 0.0025, differenceBackground * 1.7 * 1.7)
            let time = startTime + Double(offset) / sampleRate
            if (energyRise || brightnessRise) && time - lastOnset > 0.09 {
                onsetTimestamp = time; lastOnset = time; result = time
            }
            background += slow * (energy - background)
            differenceBackground += brightnessSlow * (differenceEnergy - differenceBackground)
        }
        return result
    }
}

public struct PitchTracker {
    public var detector = YINDetector()
    private var stableStart: Double?
    private var lastFrequency: Double?
    private var lastTimestamp: Double?
    public init() {}
    public mutating func analyze(_ samples: [Float], sampleRate: Double, timestamp: Double, onsetTimestamp: Double?) -> PitchFrame? {
        guard var frame = detector.detect(samples, sampleRate: sampleRate, timestamp: timestamp) else {
            stableStart = nil; lastFrequency = nil; return nil
        }
        let stable = lastFrequency.map { abs(1200 * log2(frame.frequency / $0)) < 18 } ?? false
        let continuous = lastTimestamp.map { timestamp - $0 < 0.12 } ?? false
        if !stable || !continuous { stableStart = timestamp }
        frame.isStable = timestamp - (stableStart ?? timestamp) >= 0.12
        frame.onsetTimestamp = onsetTimestamp
        lastFrequency = frame.frequency; lastTimestamp = timestamp
        return frame
    }
}

/// A bounded SPSC buffer. The audio callback only copies into preallocated memory.
final class CaptureRing: @unchecked Sendable {
    let capacity = 131072
    let values: UnsafeMutablePointer<Float>
    let times: UnsafeMutablePointer<Double>
    let writeIndex = Atomic<Int>(0)
    let readIndex = Atomic<Int>(0)
    let sampleRate = Atomic<Double>(48000)
    let droppedSamples = Atomic<Int>(0)
    init() {
        values = .allocate(capacity: capacity); values.initialize(repeating: 0, count: capacity)
        times = .allocate(capacity: capacity); times.initialize(repeating: 0, count: capacity)
    }
    deinit { values.deallocate(); times.deallocate() }
    func write(_ data: UnsafePointer<Float>, count: Int, stride: Int, rate: Double, time: Double) {
        let write = writeIndex.load(ordering: .relaxed), read = readIndex.load(ordering: .acquiring)
        let available = max(0, capacity - (write - read))
        let accepted = min(count, available)
        for i in 0..<accepted {
            let index = (write + i) % capacity
            values[index] = data[i * stride]; times[index] = time + Double(i) / rate
        }
        sampleRate.store(rate, ordering: .relaxed)
        writeIndex.store(write + accepted, ordering: .releasing)
        if accepted < count { _ = droppedSamples.wrappingAdd(count - accepted, ordering: .relaxed) }
    }
    func read(maximum: Int) -> ([Float], Double)? {
        let read = readIndex.load(ordering: .relaxed), write = writeIndex.load(ordering: .acquiring)
        let count = min(maximum, write - read)
        guard count > 0 else { return nil }
        let time = times[read % capacity]
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count { result[i] = values[(read + i) % capacity] }
        readIndex.store(read + count, ordering: .releasing)
        return (result, time)
    }
    func clear() { readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing) }
}
