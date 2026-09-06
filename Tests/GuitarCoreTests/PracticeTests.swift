import XCTest
@testable import GuitarCore

final class PracticeTests: XCTestCase {
    func frame(_ time: Double, midi: Double = 64, onset: Double? = 0, confidence: Double = 0.99, rms: Double = 0.1, stable: Bool = true) -> PitchObservation {
        PitchObservation(timestamp: time, frequency: MusicTheory.frequency(midi: midi), confidence: confidence, rms: rms, isStable: stable, onsetTimestamp: onset)
    }
    func testWaitRequires120msWithin25Cents() {
        var engine = PracticeEngine()
        engine.start(targets: [PracticeTarget(startTick: 0, endTick: 960, midi: 64)], mode: .waitForCorrect, at: 0)
        engine.consume(frame(0, midi: 64.2)); engine.consume(frame(0.05, midi: 64.2)); engine.consume(frame(0.10, midi: 64.2))
        XCTAssertFalse(engine.isFinished)
        engine.consume(frame(0.12, midi: 64.2)); XCTAssertTrue(engine.isFinished)
        XCTAssertEqual(engine.results.first?.centsError ?? 0, 20, accuracy: 0.000001)
    }
    func testWrongNoteNoiseGapAndSilenceResetStability() {
        var engine = PracticeEngine()
        engine.start(targets: [PracticeTarget(startTick: 0, endTick: 960, midi: 40)], mode: .waitForCorrect, at: 0)
        for i in 0..<10 { engine.consume(frame(Double(i) * 0.05, midi: 40.3)) }
        XCTAssertEqual(engine.index, 0)
        engine.consume(frame(0.5, midi: 40)); engine.consume(frame(0.55, midi: 40, rms: 0)); engine.consume(frame(0.6, midi: 40))
        engine.consume(frame(0.65, midi: 40, confidence: 0.1)); engine.consume(frame(0.7, midi: 40))
        engine.consume(frame(1.0, midi: 40)); XCTAssertEqual(engine.index, 0)
        engine.consume(frame(1.05, midi: 40)); engine.consume(frame(1.1, midi: 40)); engine.consume(frame(1.12, midi: 40))
        XCTAssertEqual(engine.index, 1)
    }
    func testCoreMeasuresItsOwnStabilityWithoutAddingAnalyzerDelay() {
        var engine = PracticeEngine()
        engine.start(targets: [PracticeTarget(startTick: 0, endTick: 960, midi: 64)], mode: .waitForCorrect, at: 0)
        for time in [0.0,0.04,0.08,0.12] { engine.consume(frame(time, stable: false)) }
        XCTAssertTrue(engine.isFinished)
    }
    func testWaitingStabilityAccepts100msFramesWithHostTimeAndSubMillisecondJitter() {
        for base in [0.0,113498.8299655907,3_456_789.123] {
            for requiresOnset in [false,true] {
                var engine = PracticeEngine()
                engine.start(targets: [PracticeTarget(startTick: 0, endTick: 960, midi: 40, requiresOnset: requiresOnset)], mode: .waitForCorrect, at: base)
                engine.consume(frame(base, midi: 40, onset: base))
                engine.consume(frame(base + 0.1007, midi: 40, onset: base))
                XCTAssertEqual(engine.index, 0)
                engine.consume(frame(base + 0.1996, midi: 40, onset: base))
                XCTAssertEqual(engine.index, 1, "Normal 100 ms callbacks must survive timestamp rounding and jitter")
            }
        }
    }
    func testWaitingStabilityResetsAfterMissingA100msWindow() {
        let base = 113498.8299655907
        var engine = PracticeEngine()
        engine.start(targets: [PracticeTarget(startTick: 0, endTick: 960, midi: 40, requiresOnset: true)], mode: .waitForCorrect, at: base)
        for offset in [0.0,0.1,0.3] { engine.consume(frame(base + offset, midi: 40, onset: base)) }
        XCTAssertEqual(engine.index, 0, "A 200 ms gap must discard stability before the missing window")
        engine.consume(frame(base + 0.4, midi: 40, onset: base))
        XCTAssertEqual(engine.index, 0)
        engine.consume(frame(base + 0.5, midi: 40, onset: base))
        XCTAssertEqual(engine.index, 1)
    }
    func testRepeatedNoteRequiresFreshAttack() {
        var engine = PracticeEngine()
        let targets = [PracticeTarget(startTick: 0, endTick: 960, midi: 64), PracticeTarget(startTick: 960, endTick: 1920, midi: 64, requiresOnset: true)]
        engine.start(targets: targets, mode: .waitForCorrect, at: 0)
        for time in [0.0,0.04,0.08,0.12,0.16,0.20,0.24,0.28] { engine.consume(frame(time, onset: 0)) }
        XCTAssertEqual(engine.index, 1)
        for time in [0.32,0.36,0.40,0.44] { engine.consume(frame(time, onset: 0.31)) }
        XCTAssertTrue(engine.isFinished)
    }
    func testEightRepeatedLowENotesDoNotAdvanceOnThreeSecondsOfOneAttack() {
        // Matches the real-guitar acceptance score, including its bar boundary.
        let measures = (0..<2).map { _ in
            ScoreMeasure(voices: [
                VoiceTrack(voice: .melody, events: (0..<4).map { index in
                    ScoreEvent(startTick: index * 960, notes: [GuitarNote(string: 6, fret: 0)])
                }),
                VoiceTrack(voice: .bass)
            ])
        }
        let targets = PracticeTarget.from(score: GuitarScore(measures: measures), voice: .melody)
        XCTAssertEqual(targets.map(\.midi), Array(repeating: 40, count: 8))
        XCTAssertEqual(targets.map(\.requiresOnset), [false,true,true,true,true,true,true,true])
        var engine = PracticeEngine()
        engine.start(targets: targets, mode: .waitForCorrect, at: 100)
        for index in 0...120 {
            engine.consume(frame(100 + Double(index) * 0.025, midi: 40, onset: 100))
        }
        XCTAssertEqual(engine.index, 1)
        XCTAssertEqual(engine.results.map(\.onsetTimestamp), [100])
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.status, "请重新拨弦后继续")
    }
    func testRepeatedAttackCannotUsePitchWindowCentersBeforeItsOnset() {
        var engine = PracticeEngine()
        engine.start(targets: [PracticeTarget(startTick: 0, endTick: 960, midi: 40, requiresOnset: true)], mode: .waitForCorrect, at: 10)
        for time in [10.0,10.04,10.08,10.12,10.16,10.20] {
            engine.consume(frame(time, midi: 40, onset: 10.10))
        }
        XCTAssertEqual(engine.index, 0)
        engine.consume(frame(10.24, midi: 40, onset: 10.10))
        XCTAssertTrue(engine.isFinished)
        XCTAssertEqual(engine.results.first?.onsetTimestamp, 10.10)
    }
    func testChangedAttackCannotInheritPreviousAttackStability() {
        var engine = PracticeEngine()
        engine.start(targets: [PracticeTarget(startTick: 0, endTick: 960, midi: 40, requiresOnset: true)], mode: .waitForCorrect, at: 0)
        for time in [0.0,0.04,0.08] { engine.consume(frame(time, midi: 40, onset: 0)) }
        for time in [0.12,0.16,0.20] { engine.consume(frame(time, midi: 40, onset: 0.10)) }
        XCTAssertEqual(engine.index, 0)
        engine.consume(frame(0.24, midi: 40, onset: 0.10))
        XCTAssertTrue(engine.isFinished)
        XCTAssertEqual(engine.results.first?.onsetTimestamp, 0.10)
    }
    func testOctaveErrorsNeverPass() {
        var engine = PracticeEngine()
        engine.start(targets: [PracticeTarget(startTick: 0, endTick: 960, midi: 40)], mode: .waitForCorrect, at: 0)
        for time in [0.0,0.04,0.08,0.12,0.16] { engine.consume(frame(time, midi: 52)) }
        XCTAssertEqual(engine.index, 0)
    }
    func testTimedUsesMeasuredAttackInsteadOfAnalysisCompletion() {
        var engine = PracticeEngine()
        engine.start(targets: [PracticeTarget(startTick: 0, endTick: 960, midi: 64)], mode: .timed, at: 10)
        engine.consume(frame(10.30, onset: 10.02))
        XCTAssertTrue(engine.isFinished)
        XCTAssertEqual(engine.results.first?.outcome, .correct)
        XCTAssertEqual(engine.results.first?.timingOffset ?? 0, 0.02, accuracy: 0.000001)
        XCTAssertEqual(engine.results.first?.assessedAt, 10.30)
    }
    func testMissedNoteDoesNotBlockFollowingAttackDuringAnalysisGrace() {
        var engine = PracticeEngine()
        engine.start(targets: [PracticeTarget(startTick: 0, endTick: 480, midi: 64), PracticeTarget(startTick: 480, endTick: 960, midi: 67)], mode: .timed, at: 10, bpm: 120)
        engine.consume(frame(10.35, midi: 67, onset: 10.25))
        XCTAssertTrue(engine.isFinished)
        XCTAssertEqual(engine.results.map(\.outcome), [.missed,.correct])
    }
    func testTimedRequiresActualOnsetAndReportsMissingWrongEarlyLate() {
        for test in [(nil as Double?, 64.0, PracticeOutcome.missed), (10.0, 65.0, .wrongPitch), (9.8,64.0,.early), (10.2,64.0,.late)] {
            var engine = PracticeEngine()
            engine.start(targets: [PracticeTarget(startTick: 0, endTick: 960, midi: 64)], mode: .timed, at: 10)
            engine.consume(frame(10.3, midi: test.1, onset: test.0)); engine.update(at: 10.6)
            XCTAssertEqual(engine.results.first?.outcome, test.2)
        }
    }
    func testLatencyCalibrationAndTimelineAnchor() {
        XCTAssertEqual(InputLatencyCalibration.estimate(expected: [1,2,3,4,5], detected: [1.1,2.11,3.09,4.7,5.1]) ?? 0, 0.1, accuracy: 0.000001)
        var engine = PracticeEngine(configuration: PracticeConfiguration(inputLatency: 0.1))
        engine.start(targets: [PracticeTarget(startTick: 960, endTick: 1920, midi: 64)], mode: .timed, at: 1, bpm: 60)
        engine.synchronizeTimeline(startedAt: 10)
        engine.consume(frame(11.3, onset: 11.1))
        XCTAssertEqual(engine.results.first?.timingOffset ?? 1, 0, accuracy: 0.000001)
    }
    func testDemonstrationSuspendsJudgmentAndShiftsTiming() {
        var engine = PracticeEngine()
        engine.start(targets: [PracticeTarget(startTick: 960, endTick: 1920, midi: 64)], mode: .timed, at: 0, bpm: 60)
        engine.setDemonstrating(true, at: 0.5)
        engine.consume(frame(1.1, onset: 1)); engine.update(at: 100)
        XCTAssertEqual(engine.index, 0)
        engine.setDemonstrating(false, at: 2.5)
        engine.consume(frame(3.15, onset: 3.0))
        XCTAssertEqual(engine.results.first?.outcome, .correct)
    }
    func testDemonstrationTailCannotPassWaitingTargetWithoutNewAttack() {
        var engine = PracticeEngine()
        engine.start(targets: [PracticeTarget(startTick: 0, endTick: 960, midi: 64)], mode: .waitForCorrect, at: 0)
        engine.setDemonstrating(true, at: 0.1); engine.setDemonstrating(false, at: 1)
        for time in [1.0,1.04,1.08,1.12,1.16] { engine.consume(frame(time, onset: 0.5)) }
        XCTAssertEqual(engine.index, 0)
        for time in [1.2,1.24,1.28,1.32] { engine.consume(frame(time, onset: 1.19)) }
        XCTAssertEqual(engine.results.first?.outcome, .correct)
    }
    func testPlaybackSpeedAbove300BPMAndReanchoringPreserveTiming() {
        var engine = PracticeEngine()
        let target = PracticeTarget(startTick: 960, endTick: 1920, midi: 64)
        engine.start(targets: [target], mode: .timed, at: 10, bpm: 400)
        XCTAssertEqual(engine.expectedTimestamp(for: target), 10.15, accuracy: 0.000001)
        engine.synchronizeTimeline(startedAt: 20, bpm: 600)
        XCTAssertEqual(engine.expectedTimestamp(for: target), 20.1, accuracy: 0.000001)
        engine.consume(frame(20.2, onset: 20.1))
        XCTAssertEqual(engine.results.first?.timingOffset ?? 1, 0, accuracy: 0.000001)
    }
    func testTiesSkipAndRepeatedTargetConstruction() {
        let events = [
            ScoreEvent(startTick: 0, notes: [GuitarNote(string: 1, fret: 0, tieToNext: true)]),
            ScoreEvent(startTick: 960, notes: [GuitarNote(string: 1, fret: 0)]),
            ScoreEvent(startTick: 1920, notes: [GuitarNote(string: 1, fret: 0)]),
            ScoreEvent(startTick: 2880, notes: [GuitarNote(string: 1, fret: 0),GuitarNote(string: 2, fret: 0)])]
        let score = GuitarScore(measures: [ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: events),VoiceTrack(voice: .bass)])])
        let targets = PracticeTarget.from(score: score, voice: .melody)
        XCTAssertEqual(targets.count, 3)
        XCTAssertEqual(targets.first?.endTick, 1920)
        XCTAssertTrue(targets[1].requiresOnset)
        XCTAssertNotNil(targets[2].skipReason)
        var engine = PracticeEngine()
        engine.start(targets: [targets[2]], mode: .waitForCorrect, at: 0)
        for time in [0.0,0.04,0.08,0.12] { engine.consume(frame(time)) }
        XCTAssertEqual(engine.index, 0)
        engine.manualAdvance(at: 1); XCTAssertEqual(engine.results.first?.outcome, .skipped)
        engine.start(targets: [targets[2]], mode: .timed, at: 0, bpm: 60)
        engine.update(at: 3); XCTAssertEqual(engine.results.first?.outcome, .skipped)
    }
    func testContinuousTechniquesAreExplicitlySkipped() {
        for technique in [GuitarTechnique.deadNote,.slide,.hammerOn,.pullOff,.bendHalf,.bendFull,.vibrato] {
            let note = GuitarNote(string: 1, fret: 5, technique: technique, targetFret: technique == .pullOff ? 3 : 7)
            var score = GuitarScore(); score.measures[0].voices[0].events = [ScoreEvent(startTick: 0, notes: [note])]
            XCTAssertNotNil(PracticeTarget.from(score: score, voice: .melody).first?.skipReason)
        }
    }
    func testLearningRedrawPreservesPracticeAndStabilityAcrossNewDocumentIDs() {
        let first = MusicTheory.scaleExercise(root: .c, kind: .major, pattern: .a)
        let regenerated = MusicTheory.scaleExercise(root: .c, kind: .major, pattern: .a)
        XCTAssertNotEqual(first, regenerated)
        XCTAssertTrue(first.hasSameContent(as: regenerated))
        var engine = PracticeEngine()
        // The view has requested playback, but an audio callback has not supplied its anchor yet.
        XCTAssertFalse(engine.stopIfScoreChanged(from: first, to: regenerated))
        engine.start(targets: PracticeTarget.from(score: first, voice: .melody), mode: .waitForCorrect, at: 0)
        let midi = Double(engine.currentTarget!.midi!)
        for time in [0.0,0.04,0.08,0.12] {
            let refreshed = MusicTheory.scaleExercise(root: .c, kind: .major, pattern: .a)
            XCTAssertFalse(engine.stopIfScoreChanged(from: first, to: refreshed))
            XCTAssertTrue(engine.isRunning)
            engine.consume(frame(time, midi: midi, onset: 0))
        }
        XCTAssertEqual(engine.index, 1)
        XCTAssertEqual(engine.results.first?.outcome, .correct)
        XCTAssertTrue(engine.isRunning)
    }
    func testRealScoreContentChangesCancelEitherPracticeMode() {
        let source = MusicTheory.scaleExercise(root: .c, kind: .major, pattern: .a)
        let changes: [(inout GuitarScore) -> Void] = [
            { $0.bpm = 120 }, { $0.timeSignature = TimeSignature(3,4) }, { $0.tuning[0] += 1 },
            { $0.measures[0].voices[0].events[0].notes[0].fret += 1 },
            { $0.measures[0].voices[0].events[0].notes[0].technique = .vibrato },
            { $0.measures[0].voices[0].events[0].rhythm = Rhythm(.quarter) },
            { $0.measures.append(ScoreMeasure()) }
        ]
        for mode in PracticeMode.allCases {
            for change in changes {
                var engine = PracticeEngine(), modified = source
                engine.start(targets: PracticeTarget.from(score: source, voice: .melody), mode: mode, at: 0)
                change(&modified)
                XCTAssertTrue(engine.stopIfScoreChanged(from: source, to: modified))
                XCTAssertFalse(engine.isRunning)
            }
        }
    }
}
