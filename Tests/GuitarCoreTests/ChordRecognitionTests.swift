import XCTest
@testable import GuitarCore

final class ChordRecognitionTests: XCTestCase {
    private func chroma(_ classes: [Int], weights: [Double]? = nil, floor: Double = 0) -> [Double] {
        var result = [Double](repeating: floor, count: 12)
        for (index, pitchClass) in classes.enumerated() { result[pitchClass] = weights?[index] ?? 1 }
        return result
    }
    private func bass(_ pitchClass: Int) -> [Double] { chroma([pitchClass]) }
    private func silence() -> [Double] { [Double](repeating: 0, count: 12) }

    func testVocabularyCoversEveryKindOnEveryRootWithoutDuplicates() {
        let templates = ChordVocabulary.standard
        XCTAssertEqual(templates.count, 1 + 12 * (ChordKind.allCases.count + 2))
        XCTAssertEqual(Set(templates.map(\.chord)).count, templates.count)
        XCTAssertEqual(templates.first?.chord, RecognizedChord.none)
        for template in templates.dropFirst() {
            XCTAssertEqual(sqrt(template.profile.reduce(0) { $0 + $1 * $1 }), 1, accuracy: 1e-9)
            XCTAssertEqual(template.profile.filter { $0 > 0 }.count, template.chord.pitchClasses.count)
        }
        XCTAssertTrue(templates.contains { $0.chord == .chord(ChordDefinition(root: .c, kind: .dominant9), bass: nil) })
        XCTAssertTrue(templates.contains { $0.chord == .powerChord(.e) })
        XCTAssertTrue(templates.contains { $0.chord == .singleNote(.b) })
    }

    func testLabelsAndBassAttachment() {
        let c = ChordDefinition(root: .c, kind: .major)
        XCTAssertEqual(RecognizedChord.chord(c, bass: nil).label, "C")
        XCTAssertEqual(RecognizedChord.chord(c, bass: .e).label, "C/E")
        XCTAssertEqual(RecognizedChord.chord(c, bass: .c).label, "C")
        XCTAssertEqual(RecognizedChord.chord(ChordDefinition(root: .a, kind: .minor7), bass: nil).label, "Am7")
        XCTAssertEqual(RecognizedChord.powerChord(.e).label, "E5")
        XCTAssertEqual(RecognizedChord.powerChord(.e).pitchClasses, [4, 11])
        XCTAssertEqual(RecognizedChord.singleNote(.bFlat).label, "B♭")
        XCTAssertEqual(RecognizedChord.none.label, "—")
        XCTAssertEqual(RecognizedChord.chord(c, bass: nil).attachingBass(.g), .chord(c, bass: .g))
        XCTAssertEqual(RecognizedChord.chord(c, bass: nil).attachingBass(.c), .chord(c, bass: nil))
        XCTAssertEqual(RecognizedChord.chord(c, bass: nil).attachingBass(.d), .chord(c, bass: nil), "A non-chord-tone bass never renames the chord")
        XCTAssertEqual(RecognizedChord.chord(c, bass: .e).withoutBass, .chord(c, bass: nil))
        XCTAssertEqual(RecognizedChord.powerChord(.a).attachingBass(.e), .powerChord(.a))
        XCTAssertEqual(RecognizedChord.chord(c, bass: .e).kindTitle, "大三和弦 · 转位，低音 E")
    }

    func testIdealChromaScoresItsOwnTemplateHighest() {
        for root in PitchClass.allCases {
            for kind in ChordKind.allCases {
                let chord = ChordDefinition(root: root, kind: kind)
                let scores = ChordDecoder.scores(chroma: chroma(chord.pitchClasses), bassChroma: bass(root.rawValue),
                                                 templates: ChordVocabulary.standard, bassWeight: 0.35, noChordScore: 0.82)
                let best = scores.indices.max { scores[$0] < scores[$1] }!
                XCTAssertEqual(ChordVocabulary.standard[best].chord, .chord(chord, bass: nil), "\(chord.name)")
                XCTAssertEqual(scores[best], 1.35, accuracy: 1e-9)
            }
        }
    }

    func testIdenticalPitchClassSetsAreSeparatedOnlyByTheBass() {
        // A C E G is Am7 over A and C6 over C; C D G is Csus2 over C and Gsus4 over G.
        var decoder = ChordDecoder()
        var decision = decoder.decode(chroma: chroma([9, 0, 4, 7]), bassChroma: bass(9), timestamp: 0)
        XCTAssertEqual(decision.chord, .chord(ChordDefinition(root: .a, kind: .minor7), bass: nil))
        decoder.reset()
        decision = decoder.decode(chroma: chroma([9, 0, 4, 7]), bassChroma: bass(0), timestamp: 0)
        XCTAssertEqual(decision.chord, .chord(ChordDefinition(root: .c, kind: .major6), bass: nil))
        decoder.reset()
        decision = decoder.decode(chroma: chroma([0, 2, 7]), bassChroma: bass(7), timestamp: 0)
        XCTAssertEqual(decision.chord, .chord(ChordDefinition(root: .g, kind: .suspended4), bass: nil))
        XCTAssertEqual(decision.candidates.first?.chord, decision.chord)
        XCTAssertEqual(decision.candidates.count, 3)
    }

    func testSingleNotePowerChordAndNoiseAreNotNamedAsChords() {
        var decoder = ChordDecoder()
        XCTAssertEqual(decoder.decode(chroma: chroma([4]), bassChroma: bass(4), timestamp: 0).chord, .singleNote(.e))
        decoder.reset()
        XCTAssertEqual(decoder.decode(chroma: chroma([4, 11]), bassChroma: bass(4), timestamp: 0).chord, .powerChord(.e))
        decoder.reset()
        let flat = [Double](repeating: 1, count: 12)
        let noisy = decoder.decode(chroma: flat, bassChroma: flat, timestamp: 0)
        XCTAssertEqual(noisy.chord, .none)
        XCTAssertLessThan(noisy.candidates.map(\.score).max() ?? 1, decoder.noChordScore)
        decoder.reset()
        XCTAssertEqual(decoder.decode(chroma: silence(), bassChroma: silence(), timestamp: 0).chord, .none)
    }

    func testDecisionsAreStickyButFollowSustainedEvidence() {
        var decoder = ChordDecoder()
        let c = ChordDefinition(root: .c, kind: .major), g = ChordDefinition(root: .g, kind: .major)
        var time = 0.0
        for _ in 0..<10 {
            let decision = decoder.decode(chroma: chroma(c.pitchClasses), bassChroma: bass(0), timestamp: time)
            XCTAssertEqual(decision.chord, .chord(c, bass: nil)); time += 0.043
        }
        let settled = decoder.decode(chroma: chroma(c.pitchClasses), bassChroma: bass(0), timestamp: time)
        XCTAssertGreaterThan(settled.posterior, 0.99)
        XCTAssertEqual(settled.heldDuration, time, accuracy: 1e-9)
        // One ambiguous frame (C with an extra B) must not flip the decision.
        time += 0.043
        let glitch = decoder.decode(chroma: chroma([0, 4, 7, 11]), bassChroma: bass(0), timestamp: time)
        XCTAssertEqual(glitch.chord, .chord(c, bass: nil))
        XCTAssertGreaterThan(glitch.heldDuration, 0.4)
        // A real change is followed within a few frames and restarts the held duration.
        var switched: Double?
        for _ in 0..<12 {
            time += 0.043
            let decision = decoder.decode(chroma: chroma(g.pitchClasses), bassChroma: bass(7), timestamp: time)
            if decision.chord == .chord(g, bass: nil) { switched = decision.heldDuration; break }
        }
        XCTAssertEqual(switched, 0)
        XCTAssertEqual(decoder.current, .chord(g, bass: nil))
    }

    func testSilenceRelaxesBeliefAndBreaksContinuity() {
        var decoder = ChordDecoder()
        let c = ChordDefinition(root: .c, kind: .major)
        for index in 0..<10 { _ = decoder.decode(chroma: chroma(c.pitchClasses), bassChroma: bass(0), timestamp: Double(index) * 0.043) }
        for index in 0..<30 { decoder.observeSilence(at: 0.43 + Double(index) * 0.043) }
        // After a long pause a new chord is accepted on the first frame.
        let f = ChordDefinition(root: .f, kind: .major)
        let decision = decoder.decode(chroma: chroma(f.pitchClasses), bassChroma: bass(5), timestamp: 2.0)
        XCTAssertEqual(decision.chord, .chord(f, bass: nil))
        XCTAssertEqual(decision.heldDuration, 0)
        // The same chord after a gap longer than continuityGap also restarts the clock.
        let again = decoder.decode(chroma: chroma(f.pitchClasses), bassChroma: bass(5), timestamp: 3.0)
        XCTAssertEqual(again.heldDuration, 0)
        XCTAssertEqual(decoder.decode(chroma: chroma(f.pitchClasses), bassChroma: bass(5), timestamp: 3.1).heldDuration, 0.1, accuracy: 1e-9)
    }

    func testFrameConvenienceProperties() {
        let frame = ChordFrame(timestamp: 1, chord: .chord(ChordDefinition(root: .d, kind: .minor), bass: .f), confidence: 0.9, fit: 0.95, heldDuration: 0.3)
        XCTAssertEqual(frame.label, "Dm/F")
        XCTAssertTrue(frame.isStable)
        XCTAssertFalse(ChordFrame(timestamp: 1, chord: .none, confidence: 0.5, fit: 0, heldDuration: 0.1).isStable)
        XCTAssertEqual(DetectedNote(midi: 40, salience: 1).name, "E2")
    }
}
