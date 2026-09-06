import XCTest
import GuitarCore
@testable import GuitarAudio

final class TunerReferenceTests: XCTestCase {
    private func score(midi: Int) -> GuitarScore {
        GuitarScore(tuning: [midi, 59, 55, 50, 45, 40], bpm: 60,
                    measures: [ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: [ScoreEvent(startTick: 0, rhythm: Rhythm(.half), notes: [GuitarNote(string: 1, fret: 0)])])])])
    }
    func testNonstandardA4ChangesRenderedReferenceWaveformPitch() throws {
        for midi in [38, 40, 69] {
            for a4 in [432.0, 442.0] {
                let original = score(midi: midi)
                let renderer = ScoreRenderer(score: original, referenceA4: a4)
                _ = renderer.render(frames: 4800)
                let samples = renderer.render(frames: 4096)
                let detected = try XCTUnwrap(YINDetector().detect(samples, sampleRate: 48000))
                let expected = MusicTheory.frequency(midi: Double(midi), a4: a4)
                XCTAssertLessThan(abs(1200 * log2(detected.frequency / expected)), 8, "MIDI \(midi), A4 \(a4)")
                XCTAssertEqual(renderer.score, original)
            }
        }
    }
    func testDefaultReferenceRenderingRemainsBitForBitIdenticalToExplicit440() {
        let document = score(midi: 40)
        let original = ScoreRenderer(score: document)
        let explicit = ScoreRenderer(score: document, referenceA4: 440)
        XCTAssertEqual(original.render(frames: 8192), explicit.render(frames: 8192))
    }
    func testChangedReferenceAlsoAppliesToTechniqueTargetAndSeekRestoration() {
        let event = ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [GuitarNote(string: 1, fret: 5, technique: .slide, targetFret: 7)])
        let document = GuitarScore(bpm: 60, measures: [ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: [event])])])
        let renderer = ScoreRenderer(score: document, fromTick: 1920, referenceA4: 432)
        _ = renderer.render(frames: 48000)
        XCTAssertEqual(renderer.synth.soundingFrequency(string: 1), 432 * pow(2, 2.0 / 12), accuracy: 0.01)
        XCTAssertEqual(document.tuning, MusicTheory.standardTuning)
    }
}
