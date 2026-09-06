import XCTest
@testable import GuitarCore

final class ScoreFollowerTests: XCTestCase {
    private func targets(_ pitches: [Int]) -> [PracticeTarget] {
        pitches.enumerated().map { PracticeTarget(startTick: $0.offset * 960, endTick: ($0.offset + 1) * 960, midi: $0.element) }
    }

    private func frame(_ time: Double, midi: Double = 64, onset: Double? = nil,
                       confidence: Double = 0.99, rms: Double = 0.1) -> PitchObservation {
        PitchObservation(timestamp: time, frequency: MusicTheory.frequency(midi: midi),
                         confidence: confidence, rms: rms, isStable: false, onsetTimestamp: onset)
    }

    private func play(_ follower: inout ScoreFollower, midi: Double, at time: Double, onset: Double? = nil) {
        for offset in [0.0, 0.05, 0.10, 0.15] {
            follower.consume(frame(time + offset, midi: midi, onset: onset ?? time))
        }
    }

    func testScorePositionMovesOnlyToConfirmedPlayedNotesRegardlessOfElapsedTime() {
        var follower = ScoreFollower()
        follower.start(targets: targets([64, 67, 69]), at: 10)
        play(&follower, midi: 64, at: 10)
        XCTAssertEqual(follower.nextIndex, 1)
        XCTAssertEqual(follower.currentTick, 0)
        for time in [11.0, 20, 100] { follower.consume(frame(time, rms: 0)) }
        XCTAssertEqual(follower.currentTick, 0)
        play(&follower, midi: 67, at: 200)
        XCTAssertEqual(follower.currentTick, 960)
        play(&follower, midi: 69, at: 201)
        XCTAssertEqual(follower.currentTick, 1920)
        XCTAssertTrue(follower.isFinished)
        XCTAssertFalse(follower.isRunning)
    }

    func testNoiseWrongOctaveAndUnstablePitchNeverMovePosition() {
        var follower = ScoreFollower()
        follower.start(targets: targets([40, 43]), at: 0)
        for index in 0..<10 {
            let time = Double(index) * 0.05
            follower.consume(frame(time, midi: 40, onset: 0, confidence: 0.2))
            follower.consume(frame(time + 0.01, midi: 40, onset: 0, rms: 0.0001))
        }
        play(&follower, midi: 52, at: 1)
        play(&follower, midi: 41, at: 2)
        play(&follower, midi: 40.5, at: 3)
        for index in 0..<10 {
            follower.consume(frame(4 + Double(index) * 0.04, midi: index.isMultiple(of: 2) ? 40 : 41, onset: 4))
        }
        XCTAssertNil(follower.matchedTarget)
        play(&follower, midi: 40.3, at: 5)
        XCTAssertEqual(follower.nextIndex, 1)
    }

    func testRepeatedNotesNeedNewAttackEvenWithoutRequiresOnsetMetadata() {
        var follower = ScoreFollower()
        follower.start(targets: targets([64, 64, 64]), at: 0)
        play(&follower, midi: 64, at: 0)
        for index in 4..<100 { follower.consume(frame(Double(index) * 0.05, onset: 0)) }
        XCTAssertEqual(follower.nextIndex, 1)
        play(&follower, midi: 64, at: 5)
        XCTAssertEqual(follower.nextIndex, 2)
        play(&follower, midi: 64, at: 6)
        XCTAssertTrue(follower.isFinished)
    }

    func testPitchChangeCanFollowWithoutAnotherAttackButFutureOnsetCannotSupplyEvidence() {
        var follower = ScoreFollower()
        follower.start(targets: targets([64, 67, 67]), at: 0)
        play(&follower, midi: 64, at: 0)
        play(&follower, midi: 67, at: 1, onset: 0)
        XCTAssertEqual(follower.nextIndex, 2)
        for time in [2.0, 2.05, 2.1, 2.15] { follower.consume(frame(time, midi: 67, onset: 3)) }
        XCTAssertEqual(follower.nextIndex, 2)
        play(&follower, midi: 67, at: 3)
        XCTAssertTrue(follower.isFinished)
    }

    func testLookaheadNeedsTwoPlayedNotesAndCannotJumpBeyondWindow() {
        var follower = ScoreFollower()
        follower.start(targets: targets([60, 62, 64, 65, 67, 69, 71]), at: 0)
        play(&follower, midi: 60, at: 0)
        play(&follower, midi: 64, at: 1)
        XCTAssertEqual(follower.currentTick, 0, "A lone later note is not sufficient evidence for a jump")
        for time in [1.2, 1.25, 1.3, 1.35] { follower.consume(frame(time, midi: 64, onset: 1)) }
        XCTAssertEqual(follower.currentTick, 0)
        play(&follower, midi: 65, at: 2)
        XCTAssertEqual(follower.currentTick, 2880)
        XCTAssertEqual(follower.nextTarget?.midi, 67)

        follower.start(targets: targets([60, 62, 64, 65, 67, 69, 71]), at: 10)
        play(&follower, midi: 69, at: 10)
        play(&follower, midi: 71, at: 11)
        XCTAssertNil(follower.matchedTarget)
    }

    func testExpectedNoteWinsAmbiguousRecoveryAndExpiredEvidenceCannotJump() {
        var follower = ScoreFollower()
        follower.start(targets: targets([60, 62, 60, 65]), at: 0)
        play(&follower, midi: 62, at: 0)
        play(&follower, midi: 60, at: 1)
        XCTAssertEqual(follower.currentTick, 0)

        follower.start(targets: targets([60, 62, 64, 65]), at: 10)
        play(&follower, midi: 64, at: 10)
        play(&follower, midi: 65, at: 30)
        XCTAssertNil(follower.matchedTarget)
    }

    func testPauseResumeAndResetRejectOldAudioAndRetainConfirmedPosition() {
        var follower = ScoreFollower()
        follower.start(targets: targets([64, 67, 69]), at: 0)
        play(&follower, midi: 64, at: 0)
        follower.pause()
        play(&follower, midi: 67, at: 1)
        XCTAssertEqual(follower.nextIndex, 1)
        follower.resume(at: 3)
        play(&follower, midi: 67, at: 2)
        play(&follower, midi: 67, at: 3, onset: 1)
        XCTAssertEqual(follower.nextIndex, 1)
        play(&follower, midi: 67, at: 4)
        XCTAssertEqual(follower.currentTick, 960)
        follower.reset()
        XCTAssertEqual(follower.currentTick, 0)
        XCTAssertTrue(follower.targets.isEmpty)
        XCTAssertFalse(follower.isRunning)
    }

    func testGapsAndNewAttacksMustRebuildStabilityAndRepeatedTimestampsCannotCount() {
        var follower = ScoreFollower()
        follower.start(targets: targets([64]), at: 0)
        for time in [0.0, 0.05, 0.30, 0.35] { follower.consume(frame(time, onset: 0)) }
        XCTAssertNil(follower.matchedTarget)
        for time in [0.40, 0.45, 0.50] { follower.consume(frame(time, onset: 0.40)) }
        XCTAssertNil(follower.matchedTarget)
        follower.consume(frame(0.45, onset: 0.40))
        follower.consume(frame(0.50, onset: 0.40))
        XCTAssertNil(follower.matchedTarget)
        follower.consume(frame(0.55, onset: 0.40))
        XCTAssertTrue(follower.isFinished)
    }

    func testSelectedVoiceTiesRestsAndUnsupportedEventsProduceOnlyPlayableAnchors() {
        let tied = GuitarNote(string: 1, fret: 0, tieToNext: true)
        let later = GuitarNote(string: 1, fret: 3)
        let score = GuitarScore(measures: [ScoreMeasure(voices: [
            VoiceTrack(voice: .melody, events: [
                ScoreEvent(startTick: 0, notes: [tied]),
                ScoreEvent(startTick: 960, notes: [GuitarNote(string: 1, fret: 0)]),
                ScoreEvent(startTick: 1920),
                ScoreEvent(startTick: 2880, notes: [GuitarNote(string: 1, fret: 1), GuitarNote(string: 2, fret: 0)])
            ]), VoiceTrack(voice: .bass, events: [ScoreEvent(startTick: 0, notes: [GuitarNote(string: 6, fret: 0)])])
        ]), ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: [
            ScoreEvent(startTick: 0, notes: [GuitarNote(string: 1, fret: 2, technique: .deadNote)]),
            ScoreEvent(startTick: 960, notes: [later])
        ]), VoiceTrack(voice: .bass)])])
        var follower = ScoreFollower()
        follower.start(score: score, voice: .melody, at: 0)
        XCTAssertEqual(follower.targets.map(\.midi), [64, 67])
        XCTAssertEqual(follower.targets.first?.endTick, 1920)
        XCTAssertEqual(follower.unsupportedTargetCount, 2)
        play(&follower, midi: 40, at: 0)
        XCTAssertNil(follower.matchedTarget)
        play(&follower, midi: 64, at: 1)
        XCTAssertEqual(follower.currentTick, 0)
        play(&follower, midi: 67, at: 2)
        XCTAssertEqual(follower.currentTick, 4800)
        XCTAssertEqual(follower.matchedNoteIDs, [later.id])
        follower.start(score: score, voice: .bass, at: 3)
        XCTAssertEqual(follower.targets.map(\.midi), [40])
    }

    func testEmptyAndUnsupportedScoresDoNotPretendToRun() {
        var follower = ScoreFollower()
        follower.start(score: GuitarScore(), voice: .melody, at: 0)
        XCTAssertFalse(follower.isRunning)
        XCTAssertFalse(follower.isFinished)
        follower.start(targets: [PracticeTarget(startTick: 0, endTick: 960, midi: 64, skipReason: "和弦")], at: 0)
        XCTAssertEqual(follower.unsupportedTargetCount, 1)
        XCTAssertFalse(follower.isRunning)
        follower.resume(at: 1)
        XCTAssertFalse(follower.isRunning)
    }
}
