import XCTest
@testable import GuitarCore

final class MusicTheoryTests: XCTestCase {
    func testStandardTuningAndOctaves() {
        let score = GuitarScore()
        XCTAssertEqual(score.tuning, [64,59,55,50,45,40])
        for string in 1...6 {
            let open = score.midi(for: GuitarNote(string: string, fret: 0))
            let octave = score.midi(for: GuitarNote(string: string, fret: 12))
            XCTAssertEqual(octave - open, 12)
            XCTAssertEqual(MusicTheory.frequency(midi: Double(octave)), MusicTheory.frequency(midi: Double(open)) * 2, accuracy: 0.00001)
        }
        XCTAssertEqual(MusicTheory.frequency(midi: 40), 82.406889, accuracy: 0.00001)
        XCTAssertEqual(MusicTheory.noteName(midi: 64), "E4")
    }
    func testEveryRootScaleAndSpelling() {
        for root in PitchClass.allCases {
            for kind in ScaleKind.allCases {
                let classes = MusicTheory.scalePitchClasses(root: root, kind: kind)
                XCTAssertEqual(classes.count, kind.intervals.count)
                XCTAssertEqual(Set(classes).count, classes.count)
                XCTAssertEqual(classes.first, root.rawValue)
                XCTAssertEqual(MusicTheory.spelledNotes(root: root, kind: kind).count, classes.count)
                let board = MusicTheory.fretboard(root: root, kind: kind)
                XCTAssertTrue(board.allSatisfy { classes.contains($0.pitchClass) && (0...24).contains($0.fret) })
                XCTAssertEqual(Set(board.filter(\.isRoot).map(\.pitchClass)), [root.rawValue])
            }
        }
        XCTAssertEqual(MusicTheory.spelledNotes(root: .f, kind: .major), ["F","G","A","B♭","C","D","E"])
        XCTAssertEqual(MusicTheory.spelledNotes(root: .cSharp, kind: .major), ["C♯","D♯","E♯","F♯","G♯","A♯","B♯"])
        XCTAssertEqual(MusicTheory.spelledNotes(root: .eFlat, kind: .naturalMinor), ["E♭","F","G♭","A♭","B♭","C♭","D♭"])
        XCTAssertEqual(MusicTheory.spelledNotes(root: .c, kind: .minorBlues), ["C","E♭","F","G♭","G","B♭"])
    }
    func testRelativeKeysAndFiveExplicitShapes() {
        for root in PitchClass.allCases {
            let relative = MusicTheory.relativeRoot(root: root, kind: .major)
            XCTAssertEqual(Set(MusicTheory.scalePitchClasses(root: root, kind: .major)), Set(MusicTheory.scalePitchClasses(root: relative, kind: .naturalMinor)))
            XCTAssertEqual(MusicTheory.relativeRoot(root: relative, kind: .naturalMinor), root)
            for pattern in ScalePattern.allCases {
                for kind in ScaleKind.allCases {
                    let positions = MusicTheory.fretboard(root: root, kind: kind, pattern: pattern)
                    XCTAssertFalse(positions.isEmpty)
                    XCTAssertTrue(positions.contains(where: \.isRoot), "\(root) \(kind) \(pattern)")
                    XCTAssertEqual(Set(positions.map(\.string)), Set(1...6))
                }
            }
        }
        XCTAssertEqual(MusicTheory.relativeKeyDescription(root: .f, kind: .major), "D 小调")
        for pattern in ScalePattern.allCases {
            let positions = MusicTheory.fretboard(root: .c, kind: .major, pattern: pattern)
            for string in 1...6 { XCTAssertEqual(positions.filter { $0.string == string }.map(\.fret), pattern.cMajorFrets[string - 1]) }
        }
        XCTAssertEqual(ScalePattern.a.cMajorFrets[2], [2,4,5])
    }
    func testPentatonicBoxesHaveTwoNotesPerStringAndShareRelativeMinorPositions() {
        for root in PitchClass.allCases {
            let relative = MusicTheory.relativeRoot(root: root, kind: .major)
            for pattern in ScalePattern.allCases {
                let major = MusicTheory.fretboard(root: root, kind: .majorPentatonic, pattern: pattern)
                let minor = MusicTheory.fretboard(root: relative, kind: .minorPentatonic, pattern: pattern)
                XCTAssertEqual(major.map(\.id), minor.map(\.id))
                for string in 1...6 { XCTAssertEqual(major.filter { $0.string == string }.count, 2) }
            }
        }
    }
    func testEveryBluesShapeIncludesItsPassingTonesAndEdgeExtensionsInTwelveKeys() {
        // Independent reference locations of E-flat in the five C-major/A-minor boxes.
        // Negative reference frets are clipped at the nut, not lost when transposed upward.
        let blueFrets: [ScalePattern: [(Int, Int)]] = [
            .c: [(1,-1),(2,4),(4,1),(6,-1)],
            .a: [(2,4),(4,1),(5,6)],
            .g: [(2,4),(3,8),(5,6)],
            .e: [(1,11),(3,8),(5,6),(6,11)],
            .d: [(1,11),(3,8),(4,13),(6,11)]
        ]
        for majorRoot in PitchClass.allCases {
            for minor in [false,true] {
                let root = minor ? MusicTheory.relativeRoot(root: majorRoot, kind: .major) : majorRoot
                let kind: ScaleKind = minor ? .minorBlues : .majorBlues
                let pentatonic: ScaleKind = minor ? .minorPentatonic : .majorPentatonic
                for pattern in ScalePattern.allCases {
                    let positions = MusicTheory.fretboard(root: root, kind: kind, pattern: pattern)
                    let pent = MusicTheory.fretboard(root: root, kind: pentatonic, pattern: pattern)
                    let expectedBlue = Set(blueFrets[pattern]!.compactMap { string, reference -> String? in
                        let fret = reference + majorRoot.rawValue
                        return (0...24).contains(fret) ? "\(string)-\(fret)" : nil
                    })
                    XCTAssertEqual(Set(positions.filter(\.isBlue).map(\.id)), expectedBlue, "\(root) \(kind) \(pattern)")
                    XCTAssertEqual(Set(positions.filter { !$0.isBlue }.map(\.id)), Set(pent.map(\.id)))
                    XCTAssertTrue(positions.filter(\.isBlue).allSatisfy { ($0.pitchClass - root.rawValue + 12) % 12 == (minor ? 6 : 3) })
                }
            }
        }
        let cSharp = MusicTheory.fretboard(root: .cSharp, kind: .majorBlues, pattern: .c)
        XCTAssertTrue(cSharp.contains { $0.string == 1 && $0.fret == 0 && $0.name == "E" && $0.isBlue })
    }
    func testContextualNoteNamesPreserveKeySpellingAndWrittenOctave() {
        XCTAssertEqual(MusicTheory.noteName(midi: 70, spelledName: "B♭"), "B♭4")
        XCTAssertEqual(MusicTheory.noteName(midi: 65, spelledName: "E♯"), "E♯4")
        XCTAssertEqual(MusicTheory.noteName(midi: 60, spelledName: "B♯"), "B♯3")
        XCTAssertEqual(MusicTheory.noteName(midi: 59, spelledName: "C♭"), "C♭4")
    }
    func testLearningExerciseBuilderUsesSelectedPositionsAndReturnsDownInEveryKey() throws {
        let patterns: [ScalePattern?] = [nil] + ScalePattern.allCases.map(Optional.some)
        for root in PitchClass.allCases {
            for kind in ScaleKind.allCases {
                for pattern in patterns {
                    let positions = MusicTheory.fretboard(root: root, kind: kind, pattern: pattern)
                    let score = ExerciseBuilder.score(title: "UI exercise", positions: positions, returnDown: true)
                    let events = score.measures.flatMap { $0.events(for: .melody) }
                    let actual = events.compactMap { $0.notes.first }.map { score.midi(for: $0) }
                    let ascending = Set(positions.map(\.midi)).sorted()
                    XCTAssertEqual(actual, ascending + ascending.dropLast().reversed())
                    XCTAssertTrue(events.allSatisfy { event in
                        event.rhythm == Rhythm(.eighth) && event.notes.count == 1 && positions.contains { $0.string == event.notes[0].string && $0.fret == event.notes[0].fret }
                    })
                    XCTAssertEqual(ScoreValidator.validate(score), [])
                    XCTAssertEqual(try ScoreIO.decode(ScoreIO.encode(score)), score)
                }
            }
        }
    }
    func testEveryCAGEDChordProducesItsTriad() {
        for root in PitchClass.allCases {
            for shape in ScalePattern.allCases {
                for minor in [false,true] {
                    let chord = CAGEDChord.make(root: root, shape: shape, minor: minor)
                    let expected = Set([root.rawValue,(root.rawValue + (minor ? 3 : 4)) % 12,(root.rawValue + 7) % 12])
                    let sounding = chord.positions.compactMap { p -> Int? in p.fret.map { (MusicTheory.standardTuning[p.string - 1] + $0) % 12 } }
                    XCTAssertEqual(Set(sounding), expected, "\(root) \(shape) minor=\(minor)")
                    XCTAssertEqual(chord.positions.count, 6)
                    XCTAssertTrue(chord.positions.compactMap(\.fret).allSatisfy { (0...24).contains($0) })
                    XCTAssertGreaterThanOrEqual(chord.arpeggio.count, sounding.count)
                    XCTAssertEqual(Set(chord.arpeggio.map(\.pitchClass)), expected)
                }
            }
        }
    }
    func testDiatonicTriadsEveryKey() {
        for root in PitchClass.allCases {
            let triads = DiatonicTriad.all(in: root)
            XCTAssertEqual(triads.map(\.roman), ["I","ii","iii","IV","V","vi","vii°"])
            for triad in triads {
                let base = triad.pitchClasses[0]
                let intervals = triad.pitchClasses.map { ($0 - base + 12) % 12 }
                XCTAssertEqual(intervals, triad.quality == .major ? [0,4,7] : triad.quality == .minor ? [0,3,7] : [0,3,6])
            }
        }
        XCTAssertEqual(DiatonicTriad.all(in: .f)[3].name, "B♭")
        XCTAssertEqual(DiatonicTriad.all(in: .f)[6].name, "Edim")
    }
    func testExercisesAreValidDocuments() throws {
        for root in PitchClass.allCases {
            for kind in ScaleKind.allCases {
                let score = MusicTheory.scaleExercise(root: root, kind: kind, pattern: .e)
                XCTAssertEqual(ScoreValidator.validate(score), [])
                XCTAssertEqual(try ScoreIO.decode(ScoreIO.encode(score)), score)
            }
        }
    }
}
