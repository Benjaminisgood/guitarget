import XCTest
@testable import GuitarCore

final class ChordPracticeTests: XCTestCase {
    private struct SeededRandom: RandomNumberGenerator {
        var state: UInt64 = 17
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    }

    private func card() -> ChordPracticeCard {
        let chord = ChordDefinition(root: .c, kind: .major)
        let voicing = ChordVoicing(chord: chord, frets: [0,1,0,2,3,nil], fingers: [0,1,0,2,3,nil], barres: [], fingerCount: 3)
        return ChordPracticeCard(chord: chord, voicing: voicing)
    }

    private func observation(_ time: Double, midi: Int, onset: Double) -> PitchObservation {
        PitchObservation(timestamp: time, frequency: MusicTheory.frequency(midi: Double(midi)), confidence: 0.99, rms: 0.1, onsetTimestamp: onset)
    }

    private func playCurrentString(_ session: inout ChordPracticeSession, at onset: Double) {
        guard let midi = session.engine.currentTarget?.midi else { return }
        for offset in [0.0, 0.04, 0.08, 0.12] { session.consume(observation(onset + offset, midi: midi, onset: onset)) }
    }

    func testDeckCoversSelectedSetBeforeRepeatingAndCancelsCleanly() throws {
        var random = SeededRandom()
        let deck = try ChordPracticeDeck.make(roots: [.c, .c], kinds: [.major, .minor], rounds: 8, using: &random)
        XCTAssertEqual(deck.count, 8)
        XCTAssertEqual(Set(deck.map(\.id)).count, 8)
        XCTAssertEqual(Set(deck.prefix(2).map(\.chord)), [ChordDefinition(root: .c, kind: .major), ChordDefinition(root: .c, kind: .minor)])
        XCTAssertTrue(zip(deck, deck.dropFirst()).allSatisfy { $0.chord != $1.chord })
        XCTAssertThrowsError(try ChordPracticeDeck.make(roots: [], kinds: [.major], rounds: 1, using: &random))
        XCTAssertThrowsError(try ChordPracticeDeck.make(roots: [.c], kinds: [.dominant7], rounds: 1, using: &random))
        XCTAssertThrowsError(try ChordPracticeDeck.make(roots: [.c], kinds: [.major], rounds: 1, using: &random, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testTargetsAreIndependentStringsWithExactOctavesAndFreshAttacks() {
        let card = card()
        XCTAssertEqual(card.notes.map(\.string), [5,4,3,2,1])
        XCTAssertEqual(card.targets.compactMap(\.midi), [48,52,55,60,64])
        XCTAssertTrue(card.targets.allSatisfy { $0.requiresOnset && $0.noteIDs.count == 1 && $0.skipReason == nil })
        XCTAssertEqual(card.targets.flatMap(\.noteIDs), card.notes.map(\.id))
    }

    func testMemoryHidesAtDeadlineAndDoesNotAssessPreparation() {
        var session = ChordPracticeSession()
        session.start(cards: [card()], style: .memory, assessment: .singleNotes, memorySeconds: 5, at: 10)
        session.setAudioContext(capturing: true, playbackBlocking: false, at: 10)
        session.consume(observation(11, midi: 48, onset: 10.9))
        XCTAssertTrue(session.diagramVisible)
        XCTAssertEqual(session.phase, .memorizing)
        XCTAssertTrue(session.engine.results.isEmpty)
        session.update(at: 14.99)
        XCTAssertEqual(session.phase, .memorizing)
        session.update(at: 15)
        XCTAssertEqual(session.phase, .performing)
        XCTAssertFalse(session.diagramVisible)
        session.revealDiagram()
        XCTAssertTrue(session.diagramVisible)
        XCTAssertTrue(session.usedHint)
    }

    func testListeningRequiresCompletedDemonstrationAndFreshUserAttack() {
        var session = ChordPracticeSession()
        session.start(cards: [card()], style: .listening, assessment: .singleNotes, at: 0)
        session.setAudioContext(capturing: true, playbackBlocking: false, at: 0)
        XCTAssertEqual(session.phase, .awaitingDemonstration)
        session.beginDemonstration(at: 0.1)
        for time in [0.2,0.24,0.28,0.32] { session.consume(observation(time, midi: 48, onset: 0.2)) }
        XCTAssertTrue(session.engine.results.isEmpty)
        session.finishDemonstration(completed: false, at: 1)
        XCTAssertEqual(session.phase, .awaitingDemonstration)
        session.beginDemonstration(at: 1.1)
        session.finishDemonstration(completed: true, at: 2)
        XCTAssertEqual(session.phase, .performing)
        XCTAssertFalse(session.diagramVisible)
        for time in [2.1,2.14,2.18,2.22] { session.consume(observation(time, midi: 48, onset: 1.9)) }
        XCTAssertEqual(session.engine.index, 0, "Demonstration tails must not count as a user attack")
        playCurrentString(&session, at: 2.3)
        XCTAssertEqual(session.engine.index, 1)
    }

    func testExternalPlaybackAndCaptureLossPauseWithoutScoringStaleFrames() {
        var session = ChordPracticeSession()
        session.start(cards: [card()], style: .diagram, assessment: .singleNotes, at: 0)
        session.setAudioContext(capturing: true, playbackBlocking: false, at: 0)
        playCurrentString(&session, at: 0.2)
        XCTAssertEqual(session.engine.index, 1)
        session.setAudioContext(capturing: true, playbackBlocking: true, at: 1)
        playCurrentString(&session, at: 1.2)
        XCTAssertEqual(session.engine.index, 1)
        session.setAudioContext(capturing: true, playbackBlocking: false, at: 2)
        for time in [2.1,2.14,2.18,2.22] { session.consume(observation(time, midi: 52, onset: 1.2)) }
        XCTAssertEqual(session.engine.index, 1)
        playCurrentString(&session, at: 2.3)
        XCTAssertEqual(session.engine.index, 2)
        session.setAudioContext(capturing: false, playbackBlocking: false, at: 3)
        playCurrentString(&session, at: 3.2)
        XCTAssertEqual(session.engine.index, 2)
        session.skipString(at: 3.5)
        XCTAssertEqual(session.engine.results.last?.outcome, .manual)
        session.rate(.needsWork, at: 4)
        XCTAssertEqual(session.results.first?.automaticallyPassed, 2)
        XCTAssertEqual(session.results.first?.manuallySkipped, 1)
    }

    func testSelfAssessmentNeverConvertsPitchFramesIntoChordScores() {
        var session = ChordPracticeSession()
        session.start(cards: [card(), card()], style: .diagram, assessment: .selfAssessment, at: 0)
        session.setAudioContext(capturing: true, playbackBlocking: false, at: 0)
        for time in stride(from: 0.1, through: 2.0, by: 0.04) { session.consume(observation(time, midi: 48, onset: 0.1)) }
        XCTAssertTrue(session.engine.results.isEmpty)
        session.setAudioContext(capturing: false, playbackBlocking: false, at: 3)
        session.rate(.confident, at: 4)
        session.rate(.confident, at: 4.1)
        XCTAssertEqual(session.results.count, 1)
        XCTAssertEqual(session.results.first?.automaticallyPassed, 0)
        XCTAssertEqual(session.results.first?.assessment, .selfAssessment)
        XCTAssertEqual(session.results.first?.rating, .confident)
        session.next(at: 5)
        XCTAssertEqual(session.index, 1)
        session.rate(.skipped, at: 6)
        session.next(at: 7)
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.results.count, 2)
    }

    private func chordFrame(_ chord: RecognizedChord, at time: Double, held: Double, onset: Double) -> ChordFrame {
        ChordFrame(timestamp: time, chord: chord, confidence: 0.97, fit: 0.95, heldDuration: held, onsetTimestamp: onset)
    }

    func testWholeChordAssessmentPassesOnlyForAFreshHeldMatchAndKeepsWrongChordsAsFeedback() {
        var session = ChordPracticeSession()
        let card = card()
        let target = RecognizedChord.chord(card.chord, bass: nil)
        session.start(cards: [card], style: .diagram, assessment: .wholeChord, at: 10)
        session.setAudioContext(capturing: true, playbackBlocking: false, at: 10)
        XCTAssertTrue(session.canConsumeChords)
        XCTAssertFalse(session.canConsume)
        // A chord already ringing before the prompt, or analysed before it, never counts.
        session.consume(chordFrame(target, at: 10.4, held: 0.6, onset: 9.9))
        session.consume(chordFrame(target, at: 9.95, held: 0.6, onset: 9.9))
        XCTAssertEqual(session.phase, .performing); XCTAssertNil(session.recognition)
        // A fresh strum must be held for the required duration.
        session.consume(chordFrame(target, at: 10.5, held: 0.1, onset: 10.3))
        XCTAssertNil(session.recognition)
        // A wrong chord held long enough is feedback, not a failure or a pass.
        let wrong = RecognizedChord.chord(ChordDefinition(root: .a, kind: .minor), bass: nil)
        session.consume(chordFrame(wrong, at: 10.8, held: 0.4, onset: 10.3))
        XCTAssertEqual(session.phase, .performing)
        XCTAssertEqual(session.recognition?.heard, wrong)
        XCTAssertEqual(session.recognition?.matchesTarget, false)
        XCTAssertEqual(session.recognition?.description, "识别为 Am，与目标不同")
        // Single notes and silence carry no chord verdict.
        session.consume(chordFrame(.singleNote(.c), at: 10.9, held: 0.5, onset: 10.3))
        session.consume(chordFrame(.none, at: 10.95, held: 0.5, onset: 10.3))
        XCTAssertEqual(session.recognition?.heard, wrong)
        // The matching chord with a different bass passes and reports the inversion.
        session.consume(chordFrame(.chord(card.chord, bass: .e), at: 11.6, held: 0.3, onset: 11.2))
        XCTAssertEqual(session.phase, .review)
        XCTAssertEqual(session.recognition?.matchesTarget, true)
        XCTAssertEqual(session.recognition?.description, "识别为 C/E · 根音与性质正确，低音是 E")
        XCTAssertTrue(session.results.isEmpty, "Recognition never replaces the separate self-rating")
        session.rate(.confident, at: 12)
        XCTAssertEqual(session.results.first?.recognisedCorrectly, true)
        XCTAssertEqual(session.results.first?.recognition?.heard, .chord(card.chord, bass: .e))
    }

    func testWholeChordAssessmentIgnoresDemonstrationTailsCaptureLossAndManualContinueIsNotAPass() {
        var session = ChordPracticeSession()
        let card = card()
        let target = RecognizedChord.chord(card.chord, bass: nil)
        session.start(cards: [card, card], style: .listening, assessment: .wholeChord, at: 0)
        session.setAudioContext(capturing: true, playbackBlocking: false, at: 0)
        session.beginDemonstration(at: 0.1)
        session.consume(chordFrame(target, at: 0.6, held: 0.4, onset: 0.15))
        XCTAssertNil(session.recognition)
        session.finishDemonstration(completed: true, at: 2)
        XCTAssertEqual(session.phase, .performing)
        session.consume(chordFrame(target, at: 2.3, held: 0.9, onset: 1.9))
        XCTAssertEqual(session.phase, .performing, "the demonstration's own strum is not the user's")
        session.setAudioContext(capturing: false, playbackBlocking: false, at: 2.5)
        session.consume(chordFrame(target, at: 2.9, held: 0.4, onset: 2.6))
        XCTAssertEqual(session.phase, .performing, "Closed capture cannot score")
        session.setAudioContext(capturing: true, playbackBlocking: false, at: 3)
        session.consume(chordFrame(target, at: 3.2, held: 0.4, onset: 2.8))
        XCTAssertEqual(session.phase, .performing, "a strum before capture resumed does not count")
        session.skipRecognition(at: 3.5)
        XCTAssertEqual(session.phase, .review)
        session.rate(.needsWork, at: 4)
        XCTAssertEqual(session.results.first?.recognisedCorrectly, false)
        XCTAssertNil(session.results.first?.recognition)
        session.next(at: 5)
        XCTAssertEqual(session.phase, .awaitingDemonstration)
        session.skipPreparation(at: 5.1)
        session.consume(chordFrame(target, at: 5.8, held: 0.35, onset: 5.4))
        XCTAssertEqual(session.phase, .review)
        XCTAssertEqual(session.recognition?.matchesTarget, true)
        // Self assessment never consumes chord frames.
        var passive = ChordPracticeSession()
        passive.start(cards: [self.card()], style: .diagram, assessment: .selfAssessment, at: 0)
        passive.setAudioContext(capturing: true, playbackBlocking: false, at: 0)
        passive.consume(chordFrame(target, at: 1, held: 1, onset: 0.5))
        XCTAssertEqual(passive.phase, .performing); XCTAssertNil(passive.recognition)
        passive.rate(.confident, at: 2)
        XCTAssertNil(passive.results.first?.recognition)
    }

    func testAllStringsPassingStillRequiresSeparateSelfRating() {
        var session = ChordPracticeSession()
        let card = card()
        session.start(cards: [card], style: .diagram, assessment: .singleNotes, at: 0)
        session.setAudioContext(capturing: true, playbackBlocking: false, at: 0)
        for index in card.notes.indices { playCurrentString(&session, at: 0.2 + Double(index)) }
        XCTAssertEqual(session.phase, .review)
        XCTAssertEqual(session.engine.summary.correct, 5)
        XCTAssertTrue(session.results.isEmpty, "Single-note pitch success is not a whole-chord quality assessment")
        session.next(at: 6)
        XCTAssertEqual(session.index, 0)
        session.rate(.needsWork, at: 7)
        XCTAssertEqual(session.results.first?.automaticallyPassed, 5)
        XCTAssertEqual(session.results.first?.rating, .needsWork)
    }
}
