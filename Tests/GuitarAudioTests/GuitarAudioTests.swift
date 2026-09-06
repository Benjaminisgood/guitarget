import XCTest
import GuitarCore
import AVFoundation
@testable import GuitarAudio

final class GuitarAudioTests: XCTestCase {
    private let rate = 48000.0
    private func sine(_ frequency: Double, count: Int = 4096, amplitude: Double = 0.4, harmonic: Double = 0) -> [Float] {
        (0..<count).map { i in
            let phase = 2 * Double.pi * frequency * Double(i) / rate
            return Float(amplitude * sin(phase) + harmonic * sin(2 * phase))
        }
    }
    func testKnownFrequenciesIncludingAllOpenStringsAndLowE() throws {
        for midi in [40, 45, 50, 55, 59, 64, 69, 76, 88] {
            let hz = 440 * pow(2, Double(midi - 69) / 12)
            let frame = try XCTUnwrap(YINDetector().detect(sine(hz), sampleRate: rate))
            XCTAssertEqual(frame.midi, midi)
            XCTAssertLessThan(abs(1200 * log2(frame.frequency / hz)), 3)
            XCTAssertGreaterThan(frame.confidence, 0.95)
        }
    }
    func testSilenceAndBroadbandNoiseRejected() {
        XCTAssertNil(YINDetector().detect([Float](repeating: 0, count: 4096), sampleRate: rate))
        var seed: UInt64 = 17
        let noise: [Float] = (0..<4096).map { _ in
            seed = seed &* 6364136223846793005 &+ 1
            return Float(Double(seed >> 32) / Double(UInt32.max) - 0.5)
        }
        XCTAssertNil(YINDetector().detect(noise, sampleRate: rate))
        XCTAssertNil(YINDetector().detect(sine(440, amplitude: 0.0002), sampleRate: rate))
    }
    func testDetuningAndHarmonicsDoNotFoldOctave() throws {
        let frame = try XCTUnwrap(YINDetector().detect(sine(443, amplitude: 0.4, harmonic: 0.32), sampleRate: rate))
        XCTAssertEqual(frame.midi, 69)
        XCTAssertEqual(frame.cents, 1200 * log2(443 / 440), accuracy: 2)
        let low = try XCTUnwrap(YINDetector().detect(sine(82.4069, amplitude: 0.4, harmonic: 0.35), sampleRate: rate))
        XCTAssertEqual(low.midi, 40)
    }
    func testFractionalDelaySynthCanBeDetectedForSixStrings() throws {
        for (index, midi) in [64,59,55,50,45,40].enumerated() {
            let synth = GuitarSynthesizer(sampleRate: rate)
            let hz = 440 * pow(2, Double(midi - 69) / 12)
            synth.pluck(string: index + 1, frequency: hz)
            _ = synth.render(frames: 2048)
            let frame = try XCTUnwrap(YINDetector().detect(synth.render(frames: 4096), sampleRate: rate), "midi \(midi)")
            XCTAssertEqual(frame.midi, midi)
            XCTAssertLessThan(abs(1200 * log2(frame.frequency / hz)), 15)
        }
    }
    func testSynthReleaseAndResetRemoveResidualSound() {
        let synth = GuitarSynthesizer(sampleRate: rate)
        synth.pluck(string: 6, frequency: 82.4069)
        XCTAssertGreaterThan(synth.render(frames: 1000).map { abs($0) }.max() ?? 0, 0.01)
        synth.reset()
        XCTAssertTrue(synth.render(frames: 2000).allSatisfy { $0 == 0 })
    }
    func testSynthRejectsDCBiasFromRandomExcitation() {
        let synth = GuitarSynthesizer(sampleRate: rate)
        synth.pluck(string: 6, frequency: 82.4069)
        _ = synth.render(frames: 12000)
        let samples = synth.render(frames: 48000)
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        XCTAssertLessThan(abs(mean), rms * 0.03)
    }
    func testEveryTechniqueProducesFiniteDistinctAudio() {
        var signatures: [Double] = []
        for technique in GuitarTechnique.allCases {
            let synth = GuitarSynthesizer(sampleRate: rate)
            synth.pluck(string: 2, frequency: 246.94, technique: technique, targetFrequency: 293.66)
            let samples = synth.render(frames: 16000)
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
            XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.001)
            signatures.append(samples.reduce(0) { $0 + Double($1 * $1) })
        }
        XCTAssertGreaterThan(Set(signatures.map { Int($0 * 1000) }).count, 6)
    }
    func testOnsetTimestampsPrecedePitchAnalysisAndRepeatedAttack() throws {
        var detector = OnsetDetector()
        let silence = [Float](repeating: 0, count: 128)
        for i in 0..<40 { _ = detector.process(silence[...], sampleRate: rate, startTime: 10 + Double(i * 128) / rate) }
        let attack = sine(110, count: 128)
        let first = try XCTUnwrap(detector.process(attack[...], sampleRate: rate, startTime: 10.12))
        XCTAssertEqual(first, 10.12, accuracy: 0.003)
        for i in 0..<80 { _ = detector.process(silence[...], sampleRate: rate, startTime: 10.123 + Double(i * 128) / rate) }
        let second = try XCTUnwrap(detector.process(attack[...], sampleRate: rate, startTime: 10.4))
        XCTAssertGreaterThan(second, first + 0.2)
        var tracker = PitchTracker()
        let frame = try XCTUnwrap(tracker.analyze(sine(110), sampleRate: rate, timestamp: 10.47, onsetTimestamp: second))
        XCTAssertEqual(frame.timestamp, 10.47)
        XCTAssertEqual(frame.onsetTimestamp!, second)
        XCTAssertGreaterThan(frame.timestamp - frame.onsetTimestamp!, 0.06)
    }
    func testSustainedLowEDoesNotCreateRepeatedOnsetsAndRepluckDoes() {
        var detector = OnsetDetector()
        let sustained = sine(82.4069, count: 48000)
        var attacks: [Double] = []
        for offset in stride(from: 0, to: sustained.count, by: 128) {
            if let onset = detector.process(sustained[offset..<min(offset + 128, sustained.count)], sampleRate: rate, startTime: Double(offset) / rate) { attacks.append(onset) }
        }
        XCTAssertEqual(attacks.count, 1, "A held low E must not repeatedly count as a new pluck: \(attacks)")
        var realDetector = OnsetDetector()
        let synth = GuitarSynthesizer(sampleRate: rate)
        var plucks: [Double] = []
        for block in 0..<376 {
            if block == 0 || block == 188 { synth.pluck(string: 6, frequency: 82.4069) }
            let samples = synth.render(frames: 128)
            if let onset = realDetector.process(samples[...], sampleRate: rate, startTime: Double(block * 128) / rate) { plucks.append(onset) }
        }
        XCTAssertEqual(plucks.count, 2, "Only two actual excitation attacks should count: \(plucks)")
    }
    private func onsetTimes(_ samples: [Float], sampleRate: Double, callbackFrames: Int) -> [Double] {
        var detector = OnsetDetector()
        var attacks: [Double] = []
        // Match CaptureAnalyzer: every callback is split into 128 samples and a short tail.
        for callback in stride(from: 0, to: samples.count, by: callbackFrames) {
            let end = min(callback + callbackFrames, samples.count)
            for offset in stride(from: callback, to: end, by: 128) {
                if let onset = detector.process(samples[offset..<min(offset + 128, end)], sampleRate: sampleRate, startTime: Double(offset) / sampleRate) {
                    attacks.append(onset)
                }
            }
        }
        return attacks
    }
    func testSustainedNotesDoNotRetriggerAtRealMicrophoneCallbackBoundaries() {
        for sampleRate in [44100.0, 48000.0] {
            for frequency in [82.4069, 110.0] {
                for phase in [0.0, Double.pi / 4, Double.pi / 2] {
                    let samples = (0..<Int(sampleRate * 2)).map { index -> Float in
                        let time = Double(index) / sampleRate
                        return Float(0.2 * exp(-time * 0.4) * sin(2 * .pi * frequency * time + phase))
                    }
                    let attacks = onsetTimes(samples, sampleRate: sampleRate, callbackFrames: Int(sampleRate / 10))
                    XCTAssertEqual(attacks.count, 1, "One held note at \(sampleRate) Hz, \(frequency) Hz, phase \(phase) produced \(attacks)")
                }
            }
        }
    }
    func testOnsetsAreIndependentOfCaptureChunkBoundaries() {
        for sampleRate in [44100.0, 48000.0] {
            let samples = (0..<Int(sampleRate)).map { index -> Float in
                let time = Double(index) / sampleRate
                return Float(0.2 * sin(2 * .pi * 82.4069 * time))
            }
            let continuous = onsetTimes(samples, sampleRate: sampleRate, callbackFrames: 128)
            for callbackFrames in [Int(sampleRate / 10), 1024, 257, 61] {
                XCTAssertEqual(onsetTimes(samples, sampleRate: sampleRate, callbackFrames: callbackFrames), continuous,
                               "Chunk boundaries must not alter attack timestamps at \(sampleRate) Hz with \(callbackFrames)-sample callbacks")
            }
        }
    }
    func testSustainedHarmonicLowEDoesNotCreatePeriodicFalseAttacks() {
        for sampleRate in [44100.0, 48000.0] {
            for harmonics in [4, 12] {
                for decay in [0.0, 0.4] {
                    let samples = (0..<Int(sampleRate * 3)).map { index -> Float in
                        let time = Double(index) / sampleRate
                        let phase = 2 * Double.pi * 82.406889 * time
                        let wave = (1...harmonics).reduce(0.0) { $0 + sin(phase * Double($1)) / Double($1) }
                        return Float(0.3 * exp(-decay * time) * wave)
                    }
                    for callbackFrames in [128, Int(sampleRate / 10)] {
                        let attacks = onsetTimes(samples, sampleRate: sampleRate, callbackFrames: callbackFrames)
                        XCTAssertEqual(attacks.count, 1, "A sustained \(harmonics)-harmonic low E at \(sampleRate) Hz, decay \(decay), callbacks \(callbackFrames) produced \(attacks)")
                    }
                }
            }
        }
    }
    func testFastReplucksRemainDetectableWithoutSilence() {
        for sampleRate in [44100.0, 48000.0] {
            for (string, frequency) in [(6, 82.406889), (5, 110.0)] {
                for interval in [0.120, 0.250] {
                    let synth = GuitarSynthesizer(sampleRate: sampleRate)
                    let pluckFrames = (0..<5).map { Int((Double($0) * interval * sampleRate).rounded()) }
                    let total = Int(sampleRate * (4 * interval + 0.5))
                    var samples: [Float] = []
                    for (index, frame) in pluckFrames.enumerated() {
                        synth.pluck(string: string, frequency: frequency)
                        let end = index + 1 < pluckFrames.count ? pluckFrames[index + 1] : total
                        samples.append(contentsOf: synth.render(frames: end - frame))
                    }
                    let attacks = onsetTimes(samples, sampleRate: sampleRate, callbackFrames: Int(sampleRate / 10))
                    XCTAssertEqual(attacks.count, pluckFrames.count, "Re-plucks \(interval) s apart at \(frequency) Hz, \(sampleRate) Hz: \(attacks)")
                    for (attack, frame) in zip(attacks, pluckFrames) {
                        XCTAssertEqual(attack, Double(frame) / sampleRate, accuracy: 0.020, "Attack timestamp must stay near excitation, independently of 100 ms delivery")
                    }
                }
            }
        }
    }
    func testOneHarmonicPluckAdvancesOnlyOneRepeatedPracticeTarget() throws {
        for sampleRate in [44100.0, 48000.0] {
            let events = (0..<8).map { ScoreEvent(startTick: $0 * 480, rhythm: Rhythm(.eighth), notes: [GuitarNote(string: 6, fret: 0)]) }
            let score = GuitarScore(measures: [ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: events), VoiceTrack(voice: .bass)])])
            let targets = PracticeTarget.from(score: score, voice: .melody)
            XCTAssertEqual(targets.count, 8)
            XCTAssertTrue(targets.dropFirst().allSatisfy(\.requiresOnset))
            var practice = PracticeEngine()
            practice.start(targets: targets, mode: .waitForCorrect, at: 0)
            var onset = OnsetDetector()
            var tracker = PitchTracker()
            var attacks: [Double] = []
            // Hold a harmonic-rich low E for 3 seconds, then replenish its excitation once.
            let samples = (0..<Int(sampleRate * 3.6)).map { index -> Float in
                let time = Double(index) / sampleRate
                let age = time < 3 ? time : time - 3
                let phase = 2 * Double.pi * 82.406889 * time
                let wave = (1...12).reduce(0.0) { $0 + sin(phase * Double($1)) / Double($1) }
                return Float(0.3 * exp(-age * 0.4) * wave)
            }
            let callbackFrames = Int(sampleRate / 10)
            for callback in stride(from: 0, to: samples.count, by: callbackFrames) {
                let end = min(callback + callbackFrames, samples.count)
                for offset in stride(from: callback, to: end, by: 128) {
                    if let attack = onset.process(samples[offset..<min(offset + 128, end)], sampleRate: sampleRate, startTime: Double(offset) / sampleRate) { attacks.append(attack) }
                }
                guard end >= 4096 else { continue }
                let window = Array(samples[(end - 4096)..<end])
                let analysis: [Float] = stride(from: 0, to: window.count - 1, by: 2).map { (window[$0] + window[$0 + 1]) * 0.5 }
                let frame = try XCTUnwrap(tracker.analyze(analysis, sampleRate: sampleRate / 2, timestamp: Double(end - 2048) / sampleRate, onsetTimestamp: onset.onsetTimestamp))
                XCTAssertEqual(frame.midi, 40)
                practice.consume(PitchObservation(timestamp: frame.timestamp, frequency: frame.frequency, cents: frame.cents,
                                                  confidence: frame.confidence, rms: frame.rms, isStable: frame.isStable, onsetTimestamp: frame.onsetTimestamp))
                if end == Int(sampleRate * 3) {
                    XCTAssertEqual(attacks.count, 1, "A sustained harmonic waveform must itself emit just one attack")
                    XCTAssertEqual(practice.index, 1, "One pluck must not complete eight repeated E2 notes")
                }
            }
            XCTAssertEqual(attacks.count, 2)
            XCTAssertEqual(practice.index, 2, "A genuine second excitation must still advance to the next target")
        }
    }
    func testStabilityRequires120MillisecondsAndResetsAfterSilence() throws {
        var tracker = PitchTracker()
        for i in 0..<5 {
            let frame = try XCTUnwrap(tracker.analyze(sine(440), sampleRate: rate, timestamp: Double(i) * 0.025, onsetTimestamp: 0))
            XCTAssertFalse(frame.isStable)
        }
        XCTAssertTrue(try XCTUnwrap(tracker.analyze(sine(440), sampleRate: rate, timestamp: 0.15, onsetTimestamp: 0)).isStable)
        XCTAssertNil(tracker.analyze([Float](repeating: 0, count: 4096), sampleRate: rate, timestamp: 0.175, onsetTimestamp: 0))
        XCTAssertFalse(try XCTUnwrap(tracker.analyze(sine(440), sampleRate: rate, timestamp: 0.2, onsetTimestamp: 0.2)).isStable)
    }
    private func fingerstyleScore() -> GuitarScore {
        let melody = (0..<8).map { ScoreEvent(startTick: $0 * 480, rhythm: Rhythm(.eighth), notes: [GuitarNote(string: 1, fret: $0 % 5)]) }
        let bass = [ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [GuitarNote(string: 6, fret: 0)])]
        return GuitarScore(bpm: 240, measures: [ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: melody), VoiceTrack(voice: .bass, events: bass)])])
    }
    func testWholeBarBassAndEightEighthMelodyShareOneClock() {
        let renderer = ScoreRenderer(score: fingerstyleScore(), sampleRate: rate)
        let audio = renderer.render(frames: 48000)
        XCTAssertEqual(renderer.synth.triggerCount, 9)
        XCTAssertEqual(renderer.currentTick, 3840)
        XCTAssertGreaterThan(audio.map { abs($0) }.max() ?? 0, 0.02)
        _ = renderer.render(frames: 1)
        XCTAssertTrue(renderer.finished.load(ordering: .relaxed))
        let muted = ScoreRenderer(score: fingerstyleScore(), sampleRate: rate, mutedVoices: [.melody])
        _ = muted.render(frames: 48000)
        XCTAssertEqual(muted.synth.triggerCount, 1)
    }
    func testTiesAcrossBarDoNotRetrigger() {
        let first = ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [GuitarNote(string: 6, fret: 0, tieToNext: true)])
        let next = ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [GuitarNote(string: 6, fret: 0)])
        let score = GuitarScore(bpm: 240, measures: [first, next].map { ScoreMeasure(voices: [VoiceTrack(voice: .bass, events: [$0])]) })
        let renderer = ScoreRenderer(score: score, sampleRate: rate)
        _ = renderer.render(frames: 96000)
        XCTAssertEqual(renderer.synth.triggerCount, 1)
    }
    func testSeekRestoresSustainingBassWithoutReplayingEarlierMelody() {
        let renderer = ScoreRenderer(score: fingerstyleScore(), sampleRate: rate, fromTick: 1920)
        _ = renderer.render(frames: 24000)
        XCTAssertEqual(renderer.synth.triggerCount, 5) // bass sustain and four remaining melody notes
        XCTAssertEqual(renderer.currentTick, 3840)
    }
    func testLoopRestartsCleanlyAtSelectedRangeAndSpeedKeepsPitch() throws {
        let renderer = ScoreRenderer(score: fingerstyleScore(), sampleRate: rate, loopRange: 0..<3840)
        _ = renderer.render(frames: 48000 * 2 + 1)
        XCTAssertEqual(renderer.synth.triggerCount, 20) // two complete 9-note bars then the next two attacks
        let score = GuitarScore(bpm: 60, measures: [ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: [ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [GuitarNote(string: 1, fret: 5)])])])])
        for speed in [0.5, 1.0, 2.0] {
            let sped = ScoreRenderer(score: score, sampleRate: rate, speed: speed)
            _ = sped.render(frames: 2048)
            let detected = try XCTUnwrap(YINDetector().detect(sped.render(frames: 4096), sampleRate: rate))
            XCTAssertEqual(detected.midi, 69)
            XCTAssertEqual(sped.currentTick, Int(6144 * 960 / 48000 * speed), accuracy: 1)
        }
    }
    func testCountInDoesNotAdvanceScoreAndPauseByNotRenderingPreservesState() {
        let renderer = ScoreRenderer(score: fingerstyleScore(), sampleRate: rate, countIn: true)
        _ = renderer.render(frames: 48000)
        XCTAssertEqual(renderer.currentTick, 0)
        XCTAssertEqual(renderer.synth.triggerCount, 0)
        let position = renderer.currentTick
        XCTAssertEqual(renderer.currentTick, position)
        _ = renderer.render(frames: 1)
        XCTAssertEqual(renderer.synth.triggerCount, 2)
    }
    func testDiagnosticWAVFixturesAndNumericalReport() throws {
        let requested = ProcessInfo.processInfo.environment["GUITARGET_AUDIO_DIAGNOSTICS_DIR"]
        let directory = requested.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("GuitargetAudioTests-" + UUID().uuidString)
        defer { if requested == nil { try? FileManager.default.removeItem(at: directory) } }
        let report = try AudioDiagnostics.run(outputDirectory: directory)
        XCTAssertEqual(report["passed"] as? Bool, true)
        let reference = try AVAudioFile(forReading: directory.appendingPathComponent("reference-a4.wav"))
        XCTAssertEqual(reference.processingFormat.sampleRate, 48000)
        XCTAssertEqual(reference.length, 480000)
        let demo = try AVAudioFile(forReading: directory.appendingPathComponent("steel-string-demo.wav"))
        XCTAssertGreaterThan(demo.length, 480000)
        let data = try Data(contentsOf: directory.appendingPathComponent("audio-diagnostics.json"))
        let serialized = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(serialized["realGuitarTested"] as? Bool, false)
    }
    func testCaptureRingKeepsSourceTimestampAndBoundsOverflow() throws {
        let ring = CaptureRing()
        let values = [Float](repeating: 0.5, count: ring.capacity + 20)
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count, stride: 1, rate: rate, time: 100) }
        XCTAssertEqual(ring.droppedSamples.load(ordering: .relaxed), 20)
        let first = try XCTUnwrap(ring.read(maximum: 128))
        XCTAssertEqual(first.0.count, 128); XCTAssertEqual(first.1, 100)
        let next = try XCTUnwrap(ring.read(maximum: 128))
        XCTAssertEqual(next.1, 100 + 128 / rate)
    }
}
