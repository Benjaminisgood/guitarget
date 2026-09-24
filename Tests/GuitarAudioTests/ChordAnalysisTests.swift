import XCTest
import GuitarCore
@testable import GuitarAudio

final class ChordAnalysisTests: XCTestCase {
    private let rate = 48000.0

    /// Strum a grip on the steel-string model, low string first, and render `seconds`.
    private func strum(_ frets: [Int?], sampleRate: Double, seconds: Double = 1.2, velocity: Double = 0.8, gap: Double = 0.012, detuneCents: Double = 0, synth: GuitarSynthesizer? = nil) -> [Float] {
        let synth = synth ?? GuitarSynthesizer(sampleRate: sampleRate)
        var samples: [Float] = []
        for string in (1...6).reversed() {
            guard let fret = frets[string - 1] else { continue }
            let midi = MusicTheory.standardTuning[string - 1] + fret
            synth.pluck(string: string, frequency: MusicTheory.frequency(midi: Double(midi)) * pow(2, detuneCents / 1200), velocity: velocity)
            samples.append(contentsOf: synth.render(frames: Int(sampleRate * gap)))
        }
        samples.append(contentsOf: synth.render(frames: max(0, Int(sampleRate * seconds) - samples.count)))
        return samples
    }

    private func strum(_ voicing: ChordVoicing, sampleRate: Double, seconds: Double = 1.2) -> [Float] {
        strum(voicing.frets, sampleRate: sampleRate, seconds: seconds)
    }

    /// Majority decision over the frames whose centres fall inside a time range.
    private func decision(_ frames: [ChordFrame?], from start: Double, to end: Double) -> RecognizedChord? {
        let decided = frames.compactMap { $0 }.filter { $0.timestamp > start && $0.timestamp < end }
        let votes = Dictionary(grouping: decided, by: { $0.chord.withoutBass }).mapValues(\.count)
        return votes.max { $0.value < $1.value }?.key
    }

    private func sine(_ frequency: Double, seconds: Double, amplitude: Double = 0.3, sampleRate: Double? = nil) -> [Float] {
        let rate = sampleRate ?? self.rate
        return (0..<Int(rate * seconds)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    func testOwnFFTMatchesNaiveDFTAndParseval() {
        let size = 64
        let fft = FourierTransform(size: size)
        var seed: UInt64 = 99
        let signal: [Double] = (0..<size).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(UInt32.max) - 0.25
        }
        var real = signal, imaginary = [Double](repeating: 0, count: size)
        fft.transform(real: &real, imaginary: &imaginary)
        var energy = 0.0
        for k in 0..<size {
            var re = 0.0, im = 0.0
            for n in 0..<size {
                let phase = -2 * Double.pi * Double(k * n) / Double(size)
                re += signal[n] * cos(phase); im += signal[n] * sin(phase)
            }
            XCTAssertEqual(real[k], re, accuracy: 1e-9); XCTAssertEqual(imaginary[k], im, accuracy: 1e-9)
            energy += real[k] * real[k] + imaginary[k] * imaginary[k]
        }
        XCTAssertEqual(energy / Double(size), signal.reduce(0) { $0 + $1 * $1 }, accuracy: 1e-9)
        let power = fft.powerSpectrum((0..<size).map { sin(2 * .pi * 5 * Double($0) / Double(size)) })
        XCTAssertEqual(power.count, size / 2 + 1)
        XCTAssertEqual(power.indices.max { power[$0] < power[$1] }, 5)
    }

    func testAnalyticHannResponseMatchesMeasuredWindowedSinusoid() {
        let size = 4096
        let analyzer = ChordSpectrumAnalyzer(sampleRate: rate, windowSize: size)
        for offset in [0.0, 0.3, 0.5, 1.0, 1.7, 2.5] {
            let centre = 200.0 + offset
            let samples = (0..<size).map { analyzer.window[$0] * cos(2 * .pi * centre * Double($0) / Double(size)) }
            let power = analyzer.fft.powerSpectrum(samples)
            for bin in 197...204 {
                let measured = sqrt(power[bin]) / Double(size)
                let predicted = 0.5 * ChordSpectrumAnalyzer.hannResponse(Double(bin) - centre, size: size)
                XCTAssertEqual(measured, predicted, accuracy: 0.002, "offset \(offset) bin \(bin)")
            }
        }
    }

    func testLogSpectrumPeaksOnTheNoteBinAndConservesSinusoidPower() {
        let analyzer = ChordSpectrumAnalyzer(sampleRate: rate, windowSize: 16384)
        var totals: [Double] = []
        for midi in [40, 45, 57, 69, 81, 93] {
            let frequency = MusicTheory.frequency(midi: Double(midi))
            let spectrum = analyzer.logSpectrum(sine(frequency, seconds: 16384 / rate))
            let peak = spectrum.indices.max { spectrum[$0] < spectrum[$1] }!
            XCTAssertEqual(peak, (midi - ChordSpectrumAnalyzer.lowestMIDI) * 3, "MIDI \(midi)")
            totals.append(spectrum.reduce(0) { $0 + $1 * $1 })
        }
        // The mapping is a partition of unity over frequency: total power is frequency independent.
        for total in totals { XCTAssertEqual(total / totals[0], 1, accuracy: 0.08) }
        XCTAssertEqual(ChordSpectrumAnalyzer.bin(ofFrequency: ChordSpectrumAnalyzer.frequency(ofBin: 100)), 100, accuracy: 1e-9)
    }

    func testDictionaryColumnsAreUnitHarmonicProfiles() {
        let analyzer = ChordSpectrumAnalyzer(sampleRate: rate, windowSize: 16384)
        let bins = ChordSpectrumAnalyzer.binCount
        for note in [0, 5, 20, 40, 55] {
            let column = Array(analyzer.dictionary[(note * bins)..<((note + 1) * bins)])
            XCTAssertEqual(sqrt(column.reduce(0) { $0 + $1 * $1 }), 1, accuracy: 1e-9)
            let fundamental = (ChordSpectrumAnalyzer.lowestNoteMIDI + note - ChordSpectrumAnalyzer.lowestMIDI) * 3
            XCTAssertEqual(column.indices.max { column[$0] < column[$1] }, fundamental, "note \(note)")
            if fundamental + 40 < bins {
                // Peak widths follow the FFT resolution, so compare energies around each partial, not bin heights.
                func energy(_ centre: Int) -> Double { (max(0, centre - 4)...min(bins - 1, centre + 4)).reduce(0) { $0 + column[$1] * column[$1] } }
                XCTAssertEqual(energy(fundamental + 36) / energy(fundamental), pow(analyzer.harmonicDecay, 2), accuracy: 0.05, "second partial of note \(note)")
            }
        }
        let notes = ChordSpectrumAnalyzer.noteCount
        XCTAssertEqual(analyzer.gram[0], 1, accuracy: 1e-9)
        XCTAssertGreaterThan(analyzer.gram[12], 0.3, "octave-related notes share partials")
        XCTAssertLessThan(analyzer.gram[20 * notes + 21], 0.15, "adjacent semitones in the middle register barely overlap")
        XCTAssertGreaterThan(analyzer.gram[1], analyzer.gram[20 * notes + 21], "the lowest notes overlap more: a 341 ms window resolves 2.9 Hz against a 4.9 Hz semitone")
    }

    func testNonNegativeLeastSquaresRecoversSparseMixtures() {
        let analyzer = ChordSpectrumAnalyzer(sampleRate: rate, windowSize: 16384)
        let bins = ChordSpectrumAnalyzer.binCount, notes = ChordSpectrumAnalyzer.noteCount
        var mixture = [Double](repeating: 0, count: bins)
        let truth: [Int: Double] = [8: 1.0, 15: 0.6, 27: 0.4]
        for (note, weight) in truth { for k in 0..<bins { mixture[k] += weight * analyzer.dictionary[note * bins + k] } }
        let solution = analyzer.noteSaliences(mixture)
        XCTAssertEqual(solution.count, notes)
        for (note, weight) in truth { XCTAssertEqual(solution[note], weight, accuracy: 0.02) }
        XCTAssertEqual(solution.enumerated().filter { $0.element > 0.02 && truth[$0.offset] == nil }.count, 0, "no spurious notes for an exact mixture")
        XCTAssertTrue(solution.allSatisfy { $0 >= 0 })
        // A generic small problem with a negative unconstrained optimum must clamp at zero.
        let clamped = NonNegativeLeastSquares.solve(gram: [1, 0.9, 0.9, 1], correlation: [1, 0.5], count: 2)
        XCTAssertEqual(clamped[0], 1, accuracy: 1e-6); XCTAssertEqual(clamped[1], 0)
    }

    func testTuningOffsetIsEstimatedAndCompensated() {
        let analyzer = ChordSpectrumAnalyzer(sampleRate: rate, windowSize: 16384)
        for cents in [-30.0, 0, 20, 45] {
            let spectrum = analyzer.logSpectrum(sine(440 * pow(2, cents / 1200), seconds: 16384 / rate))
            let offset = ChordSpectrumAnalyzer.tuningOffset(spectrum)
            XCTAssertEqual(offset * 100, cents, accuracy: 6, "cents \(cents)")
            let aligned = ChordSpectrumAnalyzer.shifted(spectrum, semitones: offset)
            XCTAssertEqual(aligned.indices.max { aligned[$0] < aligned[$1] }, 99, "A4 lands on its bin after compensation at \(cents) cents")
        }
        XCTAssertEqual(ChordSpectrumAnalyzer.tuningOffset([Double](repeating: 0, count: 12)), 0)
    }

    func testEveryMajorAndMinorLibraryVoicingIsRecognisedAtBothCommonSampleRates() throws {
        for sampleRate in [44100.0, 48000.0] {
            for root in PitchClass.allCases {
                for kind in [ChordKind.major, .minor] {
                    let chord = ChordDefinition(root: root, kind: kind)
                    let voicing = try XCTUnwrap(try ChordLibrary.voicings(for: chord).first)
                    let frames = ChordTracker.frames(for: strum(voicing, sampleRate: sampleRate), sampleRate: sampleRate)
                    XCTAssertEqual(decision(frames, from: 0.55, to: 1.05), .chord(chord, bass: nil), "\(chord.name) at \(sampleRate) Hz")
                }
            }
        }
    }

    func testMostLibraryVoicingsOfEveryKindAreRecognised() throws {
        var correct = 0, total = 0
        var failures: [String] = []
        for root in PitchClass.allCases {
            for kind in ChordKind.allCases {
                let chord = ChordDefinition(root: root, kind: kind)
                let voicing = try XCTUnwrap(try ChordLibrary.voicings(for: chord).first)
                let frames = ChordTracker.frames(for: strum(voicing, sampleRate: rate), sampleRate: rate)
                total += 1
                if decision(frames, from: 0.55, to: 1.05) == .chord(chord, bass: nil) { correct += 1 } else { failures.append(chord.name) }
            }
        }
        // The model's top string is 13–22 dB quieter than its bass strings, far duller than a real
        // guitar, so the few grips whose colour tone sits only on that string (B♭6, E♭add9, C♯m6)
        // can lose it after the attack; 177 of 180 library grips are named correctly.
        XCTAssertGreaterThanOrEqual(correct, 172, "\(correct)/\(total) recognised; failed: \(failures)")
    }

    func testStrummedSequenceLocksQuicklyKeepsHoldingAndNamesInversions() {
        let progression: [(ChordDefinition, [Int?])] = [
            (ChordDefinition(root: .c, kind: .major), [0, 1, 0, 2, 3, nil]),
            (ChordDefinition(root: .g, kind: .major), [3, 0, 0, 0, 2, 3]),
            (ChordDefinition(root: .a, kind: .minor), [0, 1, 2, 2, 0, nil]),
            (ChordDefinition(root: .f, kind: .major), [1, 1, 2, 3, 3, 1]),
            (ChordDefinition(root: .c, kind: .major), [0, 1, 0, 2, 3, 0])
        ]
        let synth = GuitarSynthesizer(sampleRate: rate)
        var samples: [Float] = []
        var boundaries: [Double] = []
        for (_, frets) in progression {
            boundaries.append(Double(samples.count) / rate)
            synth.reset()
            samples.append(contentsOf: strum(frets, sampleRate: rate, seconds: 1.5, synth: synth))
        }
        let frames = ChordTracker.frames(for: samples, sampleRate: rate).compactMap { $0 }
        for (index, (chord, _)) in progression.enumerated() {
            let start = boundaries[index], end = index + 1 < boundaries.count ? boundaries[index + 1] : Double(samples.count) / rate
            let segment = frames.filter { $0.timestamp >= start && $0.timestamp < end }
            let lock = segment.first { $0.chord.withoutBass == .chord(chord, bass: nil) }
            XCTAssertNotNil(lock, chord.name)
            // Window centres trail real time by half a window; the decision itself needs a few hops,
            // more when the new chord shares most of its notes with the old one (F → C/E looks like Em first).
            XCTAssertLessThan((lock?.timestamp ?? .infinity) - start, 0.4, "\(chord.name) locked late")
            // Windows centred in the last 170 ms already contain the next strum's attack.
            let settled = segment.filter { $0.timestamp > start + 0.6 && $0.timestamp < end - 0.2 }
            XCTAssertFalse(settled.isEmpty)
            XCTAssertTrue(settled.allSatisfy { $0.chord.withoutBass == .chord(chord, bass: nil) }, "\(chord.name) drifted: \(Set(settled.map(\.chord.label)))")
            XCTAssertGreaterThan(settled.map(\.confidence).min() ?? 0, 0.9, chord.name)
            XCTAssertGreaterThan(settled.map(\.fit).min() ?? 0, 0.85, chord.name)
            XCTAssertGreaterThan(settled.last?.heldDuration ?? 0, 0.6)
        }
        let inversion = frames.filter { $0.timestamp > boundaries[4] + 0.6 && $0.timestamp < Double(samples.count) / rate - 0.2 }
        XCTAssertTrue(inversion.allSatisfy { $0.chord == .chord(ChordDefinition(root: .c, kind: .major), bass: .e) }, "an open low E under a C grip is C/E")
        let rootPosition = frames.filter { $0.timestamp > boundaries[0] + 0.6 && $0.timestamp < boundaries[1] - 0.2 }
        XCTAssertTrue(rootPosition.allSatisfy { $0.chord.bass == nil })
    }

    func testDetunedInstrumentIsCompensatedAndReported() {
        let chord = ChordDefinition(root: .e, kind: .minor)
        let frames = ChordTracker.frames(for: strum([0, 0, 0, 2, 2, 0], sampleRate: rate, seconds: 1.5, detuneCents: -32), sampleRate: rate).compactMap { $0 }
        XCTAssertEqual(decision(frames, from: 0.6, to: 1.4), .chord(chord, bass: nil))
        let settled = frames.filter { $0.timestamp > 0.8 }
        XCTAssertFalse(settled.isEmpty)
        for frame in settled { XCTAssertEqual(frame.tuningCents, -32, accuracy: 8) }
        XCTAssertTrue(settled.allSatisfy { $0.notes.map(\.midi).contains(40) && $0.notes.map(\.midi).contains(47) })
    }

    func testSilenceNoiseSingleNotesAndPowerChordsAreNotChords() {
        XCTAssertTrue(ChordTracker.frames(for: [Float](repeating: 0, count: 48000), sampleRate: rate).allSatisfy { $0 == nil })
        var seed: UInt64 = 5
        let noise: [Float] = (0..<48000).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(seed >> 33) / Double(UInt32.max) - 0.5) * 0.3
        }
        let noisy = ChordTracker.frames(for: noise, sampleRate: rate).compactMap { $0 }
        XCTAssertFalse(noisy.isEmpty)
        XCTAssertTrue(noisy.filter { $0.timestamp > 0.4 }.allSatisfy { $0.chord == .none }, "broadband noise: \(Set(noisy.map(\.chord.label)))")
        let single = ChordTracker.frames(for: strum([nil, nil, nil, nil, nil, 0], sampleRate: rate), sampleRate: rate)
        XCTAssertEqual(decision(single, from: 0.5, to: 1.1), .singleNote(.e))
        let power = ChordTracker.frames(for: strum([nil, nil, nil, 2, 2, 0], sampleRate: rate), sampleRate: rate)
        XCTAssertEqual(decision(power, from: 0.5, to: 1.1), .powerChord(.e))
        let high = ChordTracker.frames(for: strum([0, nil, nil, nil, nil, nil], sampleRate: rate), sampleRate: rate)
        XCTAssertEqual(decision(high, from: 0.5, to: 1.1), .singleNote(.e))
    }

    func testChordSurvivesAddedBroadbandNoise() {
        let chord = ChordDefinition(root: .g, kind: .major)
        var seed: UInt64 = 11
        let clean = strum([3, 0, 0, 0, 2, 3], sampleRate: rate, seconds: 1.5)
        let noisy = clean.map { sample -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return sample + Float(Double(seed >> 33) / Double(UInt32.max) - 0.5) * 0.02
        }
        XCTAssertEqual(decision(ChordTracker.frames(for: noisy, sampleRate: rate), from: 0.6, to: 1.4), .chord(chord, bass: nil))
    }

    func testStreamingIsIndependentOfCaptureChunkSizeAndReportsAttackTimestamps() {
        let samples = strum([0, 1, 0, 2, 3, nil], sampleRate: rate, seconds: 1.0)
        let reference = ChordTracker.frames(for: samples, sampleRate: rate, chunk: 1024)
        for chunk in [128, 733, 4096, 8192] {
            let frames = ChordTracker.frames(for: samples, sampleRate: rate, chunk: chunk)
            XCTAssertEqual(frames.count, reference.count, "chunk \(chunk)")
            for (a, b) in zip(frames, reference) {
                XCTAssertEqual(a?.timestamp ?? -1, b?.timestamp ?? -1, accuracy: 1e-9, "chunk \(chunk)")
                XCTAssertEqual(a?.chord, b?.chord, "chunk \(chunk)")
            }
        }
        var tracker = ChordTracker(sampleRate: rate)
        XCTAssertEqual(tracker.windowSize, 16384); XCTAssertEqual(tracker.hopSize, 2048)
        XCTAssertEqual(ChordTracker.windowSize(for: 44100), 16384)
        XCTAssertEqual(ChordTracker.windowSize(for: 96000), 32768)
        XCTAssertEqual(ChordTracker.windowSize(for: 22050), 8192)
        let first = tracker.consume(Array(samples[0..<20000]), startTime: 100, onsetTimestamp: 100.002)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0]?.timestamp ?? 0, 100 + 8192 / rate, accuracy: 1e-9)
        XCTAssertEqual(first[1]?.timestamp ?? 0, 100 + (8192 + 2048) / rate, accuracy: 1e-9)
        XCTAssertEqual(first[1]?.onsetTimestamp, 100.002)
        // A timing discontinuity restarts buffering instead of stitching unrelated audio.
        let gapped = tracker.consume(Array(samples[20000..<30000]), startTime: 130, onsetTimestamp: nil)
        XCTAssertTrue(gapped.isEmpty)
        tracker.reset()
        XCTAssertTrue(tracker.consume([], startTime: 0, onsetTimestamp: nil).isEmpty)
    }

    func testAnalysisStaysWellInsideTheHopBudget() {
        let samples = strum([0, 2, 2, 1, 0, 0], sampleRate: rate, seconds: 3)
        var tracker = ChordTracker(sampleRate: rate)
        let clock = ContinuousClock()
        var frames = 0
        var elapsed = Duration.zero
        for start in stride(from: 0, to: samples.count, by: 1024) {
            let chunk = Array(samples[start..<min(start + 1024, samples.count)])
            let began = clock.now
            frames += tracker.consume(chunk, startTime: Double(start) / rate, onsetTimestamp: nil).count
            elapsed += clock.now - began
        }
        XCTAssertGreaterThan(frames, 50)
        let perFrame = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        XCTAssertLessThan(perFrame / Double(frames), 0.008, "mean analysis time per hop must stay far below the 42.7 ms hop")
    }
}
