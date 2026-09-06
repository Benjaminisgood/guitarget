import XCTest
import GuitarCore
@testable import GuitarAudio

final class AccompanimentPlaybackTests: XCTestCase {
    func testScopedPlaybackStartsAtChosenBarWithCountInAndBothVoices() {
        let events = [ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [GuitarNote(string: 1, fret: 0)])]
        let bass = [ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [GuitarNote(string: 6, fret: 0)])]
        let score = GuitarScore(bpm: 240, measures: [ScoreMeasure(), ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: events), VoiceTrack(voice: .bass, events: bass)])])
        let options = AccompanimentPlaybackOptions(loop: false, metronome: false, countIn: true)
        let renderer = options.makeRenderer(score: score, sampleRate: 48000, fromTick: 3840, includeCountIn: true)
        XCTAssertTrue(renderer.isCountingIn.load(ordering: .relaxed))
        _ = renderer.render(frames: 48000)
        XCTAssertEqual(renderer.currentTick, 3840)
        XCTAssertEqual(renderer.synth.triggerCount, 0)
        _ = renderer.render(frames: 12000)
        XCTAssertEqual(renderer.currentTick, 4800, "Scoped playback advances at speed 1")
        XCTAssertEqual(renderer.synth.triggerCount, 2, "Neither voice inherits an editor mute")
        let sought = options.makeRenderer(score: score, sampleRate: 48000, fromTick: 4800, includeCountIn: false)
        XCTAssertFalse(sought.isCountingIn.load(ordering: .relaxed))
        XCTAssertEqual(sought.currentTick, 4800)
    }
    func testScopedLoopUsesWholeScoreAndRestartsWithoutAnotherCountIn() {
        let event = ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [GuitarNote(string: 6, fret: 0)])
        let score = GuitarScore(bpm: 240, measures: [ScoreMeasure(voices: [VoiceTrack(voice: .bass, events: [event])])])
        let renderer = AccompanimentPlaybackOptions(loop: true, metronome: false, countIn: false)
            .makeRenderer(score: score, sampleRate: 48000, fromTick: 0, includeCountIn: true)
        _ = renderer.render(frames: 60000)
        XCTAssertEqual(renderer.currentTick, 960)
        XCTAssertEqual(renderer.synth.triggerCount, 2)
        XCTAssertFalse(renderer.finished.load(ordering: .relaxed))
        XCTAssertFalse(renderer.isCountingIn.load(ordering: .relaxed))
    }
}
