import Foundation
import GuitarCore

/// Six independent fractional-delay Karplus–Strong strings with shared wooden-body modes.
/// All storage is allocated at construction; sample(), pluck(), and reset() allocate nothing.
public final class GuitarSynthesizer: @unchecked Sendable {
    public let sampleRate: Double
    private let strings: [PluckedString]
    private let reverb: UnsafeMutablePointer<Double>
    private let reverbLength: Int
    private var reverbIndex = 0
    private var dcInput = 0.0, dcOutput = 0.0
    private let dcCoefficient: Double
    private var bodyA = Resonator(frequency: 108, radius: 0.975, sampleRate: 48000)
    private var bodyB = Resonator(frequency: 205, radius: 0.965, sampleRate: 48000)
    private var bodyC = Resonator(frequency: 440, radius: 0.95, sampleRate: 48000)
    public private(set) var triggerCount = 0
    public init(sampleRate: Double = 48000) {
        self.sampleRate = sampleRate
        dcCoefficient = exp(-2 * .pi * 12 / sampleRate)
        strings = (0..<6).map { PluckedString(sampleRate: sampleRate, seed: UInt64($0 + 1) * 1234567) }
        reverbLength = Int(sampleRate * 0.113) + 1
        reverb = .allocate(capacity: reverbLength); reverb.initialize(repeating: 0, count: reverbLength)
        bodyA = Resonator(frequency: 108, radius: 0.975, sampleRate: sampleRate)
        bodyB = Resonator(frequency: 205, radius: 0.965, sampleRate: sampleRate)
        bodyC = Resonator(frequency: 440, radius: 0.95, sampleRate: sampleRate)
    }
    deinit { reverb.deallocate() }
    public func pluck(string: Int, frequency: Double, velocity: Double = 0.75, technique: GuitarTechnique = .none, targetFrequency: Double? = nil, age: Double = 0, duration: Double? = nil) {
        guard (1...6).contains(string), frequency > 0 else { return }
        strings[string - 1].pluck(frequency: frequency, velocity: velocity, technique: technique, targetFrequency: targetFrequency, age: age, duration: duration)
        triggerCount += 1
    }
    /// Copies already aged delay lines without reallocating or exciting the strings again.
    /// The source snapshot is prepared off the audio callback and remains immutable.
    func restoreSound(from source: GuitarSynthesizer, restoredNotes: Int) {
        for index in strings.indices { strings[index].restore(from: source.strings[index]) }
        reverb.update(from: source.reverb, count: reverbLength); reverbIndex = source.reverbIndex
        bodyA = source.bodyA; bodyB = source.bodyB; bodyC = source.bodyC
        dcInput = source.dcInput; dcOutput = source.dcOutput
        triggerCount += restoredNotes
    }
    func soundingFrequency(string: Int) -> Double { strings[string - 1].currentFrequency }
    /// Offline preparation of one string's history, leaving the other five unchanged.
    func advanceString(string: Int, frames: Int) {
        for _ in 0..<max(0, frames) { _ = strings[string - 1].sample() }
    }
    public func release(string: Int) { if (1...6).contains(string) { strings[string - 1].release() } }
    public func reset() {
        for string in strings { string.reset() }
        reverb.update(repeating: 0, count: reverbLength); reverbIndex = 0
        bodyA.reset(); bodyB.reset(); bodyC.reset()
        dcInput = 0; dcOutput = 0
    }
    @inline(__always) public func sample() -> Float {
        var dry = 0.0
        for string in strings { dry += string.sample() }
        let body = dry + 0.24 * bodyA.process(dry) + 0.13 * bodyB.process(dry) + 0.07 * bodyC.process(dry)
        let delayed = reverb[reverbIndex]
        reverb[reverbIndex] = body * 0.16 + delayed * 0.35
        reverbIndex += 1; if reverbIndex == reverbLength { reverbIndex = 0 }
        let combined = body + delayed * 0.22
        // Remove the random excitation's DC component before it reaches a speaker.
        let highPassed = combined - dcInput + dcCoefficient * dcOutput
        dcInput = combined; dcOutput = highPassed
        let output = highPassed * 0.39
        return Float(output / (1 + abs(output) * 0.35))
    }
    public func render(frames: Int) -> [Float] {
        (0..<max(0, frames)).map { _ in sample() }
    }
}

private struct Resonator {
    let a: Double, b: Double, gain: Double
    var y1 = 0.0, y2 = 0.0
    init(frequency: Double, radius: Double, sampleRate: Double) {
        a = 2 * radius * cos(2 * .pi * frequency / sampleRate); b = radius * radius; gain = (1 - radius) * 0.30
    }
    mutating func process(_ x: Double) -> Double {
        let value = gain * x + a * y1 - b * y2; y2 = y1; y1 = value; return value
    }
    mutating func reset() { y1 = 0; y2 = 0 }
}

private final class PluckedString {
    let sampleRate: Double
    let capacity = 4096
    let delay: UnsafeMutablePointer<Double>
    var write = 0
    var seed: UInt64
    var frequency = 440.0, targetFrequency = 440.0, old = 0.0
    var velocity = 0.75, age = 0.0, gain = 0.0, releaseGain = 1.0
    var technique = GuitarTechnique.none
    var releasing = false
    var transitionDuration = 0.22
    init(sampleRate: Double, seed: UInt64) {
        self.sampleRate = sampleRate; self.seed = seed
        delay = .allocate(capacity: capacity); delay.initialize(repeating: 0, count: capacity)
    }
    deinit { delay.deallocate() }
    func reset() { delay.update(repeating: 0, count: capacity); gain = 0; old = 0; releasing = false }
    @inline(__always) func noise() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double((seed >> 32) & 0xFFFFFFFF) / Double(UInt32.max) * 2 - 1
    }
    func restore(from source: PluckedString) {
        delay.update(from: source.delay, count: capacity)
        write = source.write; seed = source.seed; frequency = source.frequency
        targetFrequency = source.targetFrequency; old = source.old; velocity = source.velocity
        age = source.age; gain = source.gain; releaseGain = source.releaseGain
        technique = source.technique; releasing = source.releasing; transitionDuration = source.transitionDuration
    }
    func pluck(frequency: Double, velocity: Double, technique: GuitarTechnique, targetFrequency: Double?, age: Double, duration: Double?) {
        let legato = (technique == .hammerOn || technique == .pullOff) && gain > 0.0001
        let previous = self.frequency
        self.frequency = frequency; self.targetFrequency = targetFrequency ?? frequency
        self.velocity = min(1, max(0.05, velocity)); self.technique = technique
        self.age = 0; releasing = false; releaseGain = 1
        let nominal = technique == .slide ? 0.20 : (technique == .hammerOn ? 0.018 : (technique == .pullOff ? 0.032 : 0.22))
        transitionDuration = max(1 / sampleRate, min(nominal, (duration ?? (nominal * 2)) * 0.7))
        if legato {
            self.frequency = targetFrequency == nil ? previous : frequency
            self.targetFrequency = targetFrequency ?? frequency
            gain = max(gain * (technique == .pullOff ? 0.76 : 0.88), velocity * (technique == .pullOff ? 0.57 : 0.68)); return
        }
        delay.update(repeating: 0, count: capacity); write = 0; old = 0
        let period = min(capacity - 2, max(2, Int(sampleRate / frequency)))
        var last = 0.0
        for i in 0..<(period + 2) {
            // A filtered pick excitation with a small triangular displacement component.
            let white = noise()
            let bright = self.velocity * 0.66 + 0.22
            last = white * bright + last * (1 - bright)
            let phase = Double(i) / Double(period)
            let triangle = (1 - abs(2 * phase - 1)) * 2 - 1
            delay[(capacity - period + i) % capacity] = last * 0.85 + triangle * 0.15
        }
        gain = self.velocity
        if technique == .deadNote { gain *= 0.58 }
        // This path is used only while preparing a renderer off the realtime thread.
        // Age the physical delay line, including its low-pass loss, rather than merely
        // reducing a new pick excitation's gain. Loop callbacks restore a cached state.
        for _ in 0..<max(0, Int(age * sampleRate)) { _ = sample() }
    }
    func release() { releasing = true }
    var currentFrequency: Double {
        var current = frequency
        if technique == .slide || technique == .hammerOn || technique == .pullOff {
            current *= pow(targetFrequency / max(1, frequency), min(1, age / transitionDuration))
        } else if technique == .bendHalf || technique == .bendFull {
            let semitones = technique == .bendHalf ? 1.0 : 2.0
            current *= pow(2, semitones / 12 * min(1, age / transitionDuration))
        } else if technique == .vibrato {
            current *= pow(2, sin(age * 2 * .pi * 5.6) * 0.20 / 12 * min(1, age / 0.15))
        }
        return current
    }
    @inline(__always) func sample() -> Double {
        guard gain > 0.000005 else { return 0 }
        let current = currentFrequency
        let length = min(Double(capacity - 2), max(2, sampleRate / current - 0.5))
        var read = Double(write) - length
        if read < 0 { read += Double(capacity) }
        let a = Int(read), fraction = read - Double(a)
        let value = delay[a] * (1 - fraction) + delay[(a + 1) % capacity] * fraction
        let decay = technique == .palmMute ? 0.10 : (technique == .deadNote ? 0.022 : 2.2)
        let feedback = exp(-1 / (current * decay))
        let filtered = (value + old) * 0.5
        delay[write] = filtered * feedback
        old = value; write += 1; if write == capacity { write = 0 }
        age += 1 / sampleRate
        if releasing { releaseGain *= exp(-1 / (0.012 * sampleRate)) }
        if releaseGain < 0.0001 { gain = 0 }
        let attack = min(1, age * sampleRate / 32)
        if technique == .deadNote {
            return (noise() * 0.7 + value * 0.3) * gain * exp(-age / 0.014) * releaseGain * attack
        }
        return value * gain * releaseGain * attack
    }
}
