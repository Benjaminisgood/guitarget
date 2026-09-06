import Foundation
import GuitarCore
import Synchronization

struct RenderNote {
    var start: Int64, end: Int64
    var string: Int
    var frequency: Double, velocity: Double
    var technique: GuitarTechnique
    var targetFrequency: Double?
}

/// One source node owns one renderer, so both score voices share a single sample clock.
/// The owner stops the engine before replacing a renderer. No model/UI mutation occurs here.
public final class ScoreRenderer: @unchecked Sendable {
    public let sampleRate: Double
    public let ticksPerSample: Double
    public let position = Atomic<Int64>(0)
    public let finished = Atomic<Bool>(false)
    public let isCountingIn = Atomic<Bool>(false)
    public let hostAnchor = Atomic<Double>(-Double.infinity)
    public let synth: GuitarSynthesizer
    private let notes: [RenderNote]
    private var startIndex = 0
    private var releases: [Int64] = .init(repeating: -1, count: 6)
    private let endSample: Int64
    private var samplePosition: Int64 = 0
    private let loop: Range<Int64>?
    private let metronome: Bool
    private let beatSamples: Int64
    private let beatsPerBar: Int
    private var clickAge = 999999
    private var clickHigh = false
    private let countInSamples: Int64
    private var countInRemaining: Int64 = 0
    private let requestedStartTick: Int
    private var loopSnapshot: GuitarSynthesizer?
    private var loopStartIndex = 0
    private var loopReleases: [Int64] = .init(repeating: -1, count: 6)
    private var loopSustainCount = 0
    private var resumeFadeRemaining = 0
    public let score: GuitarScore
    public init(score: GuitarScore, sampleRate: Double = 48000, speed: Double = 1, fromTick: Int = 0, loopRange: Range<Int>? = nil, mutedVoices: Set<ScoreVoice> = [], metronome: Bool = false, countIn: Bool = false, referenceA4: Double = 440) {
        self.score = score; self.sampleRate = sampleRate
        let referenceA4 = referenceA4.isFinite && referenceA4 > 0 ? referenceA4 : 440
        requestedStartTick = max(0, min(fromTick, score.totalTicks))
        ticksPerSample = score.bpm * max(0.2, min(3, speed)) * Double(ticksPerQuarter) / (60 * sampleRate)
        let ticksPerSample = self.ticksPerSample
        notes = ScoreScheduler.notes(score).filter { !mutedVoices.contains($0.voice) }.map { item in
            RenderNote(start: Int64((Double(item.startTick) / ticksPerSample).rounded()), end: Int64((Double(item.endTick) / ticksPerSample).rounded()), string: item.note.string, frequency: referenceA4 * pow(2, Double(item.midi - 69) / 12), velocity: item.note.velocity, technique: item.note.technique, targetFrequency: item.note.targetFret.map { referenceA4 * pow(2, Double(score.tuning[item.note.string - 1] + $0 - 69) / 12) })
        }.sorted { $0.start < $1.start }
        endSample = Int64((Double(score.totalTicks) / ticksPerSample).rounded())
        loop = loopRange.flatMap { range in
            let lower = max(0, range.lowerBound), upper = min(score.totalTicks, range.upperBound)
            guard upper > lower else { return nil }
            return Int64((Double(lower) / ticksPerSample).rounded())..<Int64((Double(upper) / ticksPerSample).rounded())
        }
        self.metronome = metronome
        let beatTicks = score.timeSignature.denominator == 8 ? 1440 : 960
        beatSamples = max(1, Int64((Double(beatTicks) / ticksPerSample).rounded()))
        beatsPerBar = score.timeSignature.denominator == 8 ? max(1, score.timeSignature.numerator / 3) : score.timeSignature.numerator
        countInSamples = countIn ? beatSamples * Int64(beatsPerBar) : 0
        synth = GuitarSynthesizer(sampleRate: sampleRate)
        // Warm sustained strings only during construction. A loop copies this immutable
        // snapshot in bounded time; it never simulates seconds of history in the callback.
        if let loop {
            let snapshot = GuitarSynthesizer(sampleRate: sampleRate)
            for (index, note) in notes.enumerated() where note.start < loop.lowerBound {
                loopStartIndex += 1
                if note.end > loop.lowerBound {
                    restoreSustainedNote(at: index, to: loop.lowerBound, into: snapshot)
                    loopReleases[note.string - 1] = note.end
                    loopSustainCount += 1
                }
            }
            loopSnapshot = snapshot
        }
        prepare(at: Int64((Double(requestedStartTick) / ticksPerSample).rounded()))
        countInRemaining = countInSamples
        isCountingIn.store(countInRemaining > 0, ordering: .relaxed)
        position.store(samplePosition - countInRemaining, ordering: .relaxed)
    }
    private func prepare(at target: Int64) {
        if let loop, target == loop.lowerBound, let loopSnapshot {
            synth.restoreSound(from: loopSnapshot, restoredNotes: loopSustainCount)
            for index in 0..<6 { releases[index] = loopReleases[index] }
            samplePosition = target; startIndex = loopStartIndex
            resumeFadeRemaining = loopSustainCount > 0 ? Int(sampleRate * 0.004) : 0
            return
        }
        synth.reset(); releases.withUnsafeMutableBufferPointer { $0.update(repeating: -1) }
        samplePosition = target; startIndex = 0
        while startIndex < notes.count && notes[startIndex].start < target {
            let note = notes[startIndex]
            if note.end > target {
                restoreSustainedNote(at: startIndex, to: target, into: synth)
                releases[note.string - 1] = note.end
                resumeFadeRemaining = Int(sampleRate * 0.004)
            }
            startIndex += 1
        }
    }
    /// A hammer-on/pull-off inherits the preceding string vibration. Reconstruct
    /// that connected chain back to its pick excitation, even if earlier notes
    /// have ended before the seek point. Called only during renderer construction.
    private func restoreSustainedNote(at index: Int, to target: Int64, into destination: GuitarSynthesizer) {
        var chain = [index]
        var first = index
        while notes[first].technique == .hammerOn || notes[first].technique == .pullOff {
            guard let previous = notes[..<first].lastIndex(where: { $0.string == notes[first].string }),
                  notes[previous].end >= notes[first].start else { break }
            chain.append(previous); first = previous
        }
        chain.reverse()
        for (offset, noteIndex) in chain.enumerated() {
            let note = notes[noteIndex]
            destination.pluck(string: note.string, frequency: note.frequency, velocity: note.velocity,
                              technique: note.technique, targetFrequency: note.targetFrequency,
                              duration: Double(note.end - note.start) / sampleRate)
            let end = offset + 1 < chain.count ? notes[chain[offset + 1]].start : target
            destination.advanceString(string: note.string, frames: Int(end - note.start))
        }
    }
    public var currentTick: Int {
        isCountingIn.load(ordering: .acquiring) ? requestedStartTick : max(0, Int(Double(position.load(ordering: .relaxed)) * ticksPerSample))
    }
    @inline(__always) public func sample() -> Float {
        if countInRemaining > 0 {
            if countInRemaining % beatSamples == 0 {
                clickAge = 0; clickHigh = countInRemaining == countInSamples
            }
            countInRemaining -= 1
            return clickSample()
        }
        if let loop, samplePosition >= loop.upperBound { prepare(at: loop.lowerBound) }
        if samplePosition >= endSample {
            finished.store(true, ordering: .relaxed); return 0
        }
        if samplePosition >= 0 {
            for string in 0..<6 {
                if releases[string] >= 0 && samplePosition >= releases[string] { synth.release(string: string + 1); releases[string] = -1 }
            }
            while startIndex < notes.count && notes[startIndex].start <= samplePosition {
                let note = notes[startIndex]
                if note.end > samplePosition {
                    synth.pluck(string: note.string, frequency: note.frequency, velocity: note.velocity, technique: note.technique, targetFrequency: note.targetFrequency, duration: Double(note.end - note.start) / sampleRate)
                    releases[note.string - 1] = note.end
                }
                startIndex += 1
            }
        }
        if (metronome || samplePosition < 0), samplePosition % beatSamples == 0 {
            clickAge = 0; clickHigh = (samplePosition / beatSamples) % Int64(beatsPerBar) == 0
        }
        var value = samplePosition < 0 ? Float(0) : synth.sample()
        if resumeFadeRemaining > 0 {
            value *= Float(1 - Double(resumeFadeRemaining) / (sampleRate * 0.004))
            resumeFadeRemaining -= 1
        }
        value += clickSample()
        samplePosition += 1
        return value
    }
    @inline(__always) private func clickSample() -> Float {
        guard clickAge < Int(sampleRate * 0.038) else { return 0 }
        let time = Double(clickAge) / sampleRate
        clickAge += 1
        return Float(sin(time * 2 * .pi * (clickHigh ? 1700 : 1150)) * exp(-time / 0.007) * 0.15)
    }
    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames { buffer[i] = sample() }
        position.store(samplePosition - countInRemaining, ordering: .releasing)
        isCountingIn.store(countInRemaining > 0, ordering: .releasing)
    }
    public func render(frames: Int) -> [Float] {
        var result = [Float](repeating: 0, count: max(0, frames))
        result.withUnsafeMutableBufferPointer { render(into: $0.baseAddress!, frames: frames) }
        return result
    }
}
