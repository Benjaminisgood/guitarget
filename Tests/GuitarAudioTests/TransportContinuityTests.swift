import XCTest
import GuitarCore
@testable import GuitarAudio

final class TransportContinuityTests: XCTestCase {
    func testNonzeroCountInKeepsDisplayAtRequestedBarButPreservesClockAnchor() {
        let score = GuitarScore(bpm: 240, measures: [ScoreMeasure(), ScoreMeasure()])
        let renderer = ScoreRenderer(score: score, fromTick: 3840, countIn: true)
        XCTAssertTrue(renderer.isCountingIn.load(ordering: .relaxed))
        XCTAssertEqual(renderer.currentTick, 3840)
        XCTAssertEqual(renderer.position.load(ordering: .relaxed), 0)
        _ = renderer.render(frames: 24000)
        XCTAssertEqual(renderer.currentTick, 3840)
        XCTAssertTrue(renderer.isCountingIn.load(ordering: .relaxed))
        XCTAssertEqual(renderer.synth.triggerCount, 0)
        _ = renderer.render(frames: 24000)
        XCTAssertFalse(renderer.isCountingIn.load(ordering: .relaxed))
        XCTAssertEqual(renderer.currentTick, 3840)
        _ = renderer.render(frames: 12000)
        XCTAssertEqual(renderer.currentTick, 4800)
    }

    func testShortScoreTechniquesReachTheirMarkedTargetBeforeReleaseAtEverySpeed() {
        for technique in [GuitarTechnique.bendHalf, .bendFull, .slide, .hammerOn, .pullOff] {
            for speed in [0.5, 1.0, 3.0] {
                let targeted = [.slide, .hammerOn, .pullOff].contains(technique)
                let note = GuitarNote(string: 1, fret: 5, technique: technique, targetFret: targeted ? (technique == .pullOff ? 3 : 7) : nil)
                let event = ScoreEvent(startTick: 0, rhythm: Rhythm(.thirtySecond), notes: [note])
                let renderer = ScoreRenderer(score: GuitarScore(bpm: 80, measures: [ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: [event])])]), speed: speed)
                let frames = Int(Double(event.rhythm.ticks) / renderer.ticksPerSample * 0.85)
                _ = renderer.render(frames: frames)
                let expected = 440 * pow(2, (technique == .bendHalf ? 1.0 : (technique == .pullOff ? -2.0 : 2.0)) / 12)
                XCTAssertEqual(renderer.synth.soundingFrequency(string: 1), expected, accuracy: 0.01, "\(technique), speed \(speed)")
            }
        }
    }

    func testSeekInsideLegatoRestoresItsPrecedingStringVibration() {
        for technique in [GuitarTechnique.hammerOn, .pullOff] {
            let events = [ScoreEvent(startTick: 0, rhythm: Rhythm(.half), notes: [GuitarNote(string: 6, fret: 5)]),
                          ScoreEvent(startTick: 1920, rhythm: Rhythm(.half), notes: [GuitarNote(string: 6, fret: 5, technique: technique, targetFret: technique == .pullOff ? 3 : 7)])]
            let score = GuitarScore(bpm: 60, measures: [ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: events)])])
            let continuous = ScoreRenderer(score: score), sought = ScoreRenderer(score: score, fromTick: 2400)
            _ = continuous.render(frames: 120000)
            _ = continuous.render(frames: 36000); _ = sought.render(frames: 36000)
            let expected = continuous.render(frames: 4096), actual = sought.render(frames: 4096)
            let energy = expected.reduce(0.0) { $0 + Double($1 * $1) }
            let error = zip(expected, actual).reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) }
            XCTAssertGreaterThan(energy, 0.000001)
            XCTAssertLessThan(sqrt(error / energy), 0.03, "\(technique)")
        }
    }

    func testAgedStringMatchesAnUninterruptedDecayAfterBodyTailSettles() {
        let continuous = GuitarSynthesizer(), restored = GuitarSynthesizer()
        continuous.pluck(string: 6, frequency: 82.406889)
        _ = continuous.render(frames: 96000)
        restored.pluck(string: 6, frequency: 82.406889, age: 2)
        // Shared body/reverb intentionally begin anew on seek. Allow their old tail
        // to settle, then compare actual waveforms rather than only trigger counts.
        _ = continuous.render(frames: 36000); _ = restored.render(frames: 36000)
        let expected = continuous.render(frames: 4096), actual = restored.render(frames: 4096)
        let energy = expected.reduce(0.0) { $0 + Double($1 * $1) }
        let error = zip(expected, actual).reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) }
        XCTAssertGreaterThan(energy, 0.000001)
        XCTAssertLessThan(sqrt(error / energy), 0.02)
    }

    func testSoundSnapshotRestoresDelayLinesBodyAndReverbExactly() {
        let playing = GuitarSynthesizer(), snapshot = GuitarSynthesizer()
        playing.pluck(string: 6, frequency: 82.406889)
        playing.pluck(string: 1, frequency: 440, technique: .vibrato)
        _ = playing.render(frames: 30000)
        snapshot.restoreSound(from: playing, restoredNotes: 2)
        XCTAssertEqual(snapshot.render(frames: 4096), playing.render(frames: 4096))
    }

    func testLoopInsideSustainedNoteRestoresSameAgedWaveformEachPass() {
        let event = ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [GuitarNote(string: 6, fret: 0)])
        let score = GuitarScore(bpm: 120, measures: [ScoreMeasure(voices: [VoiceTrack(voice: .bass, events: [event])])])
        let renderer = ScoreRenderer(score: score, fromTick: 1920, loopRange: 1920..<2880)
        let first = renderer.render(frames: 24000), second = renderer.render(frames: 24000)
        XCTAssertEqual(first, second)
        XCTAssertEqual(renderer.synth.triggerCount, 2)
        XCTAssertGreaterThan(first.map { abs($0) }.max() ?? 0, 0.001)
    }
}
