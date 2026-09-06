import XCTest
@testable import GuitarCore

final class ChordLibraryTests: XCTestCase {
    func testDefinitionsTransposeEveryKindToTwelveRootsWithCorrectSpelling() throws {
        XCTAssertEqual(ChordKind.allCases.count, 15)
        for root in PitchClass.allCases {
            for kind in ChordKind.allCases {
                let chord = ChordDefinition(root: root, kind: kind)
                XCTAssertEqual(chord.pitchClasses, kind.intervals.map { ($0 + root.rawValue) % 12 })
                XCTAssertEqual(Set(chord.pitchClasses).count, kind.intervals.count)
                XCTAssertEqual(chord.degrees.count, chord.noteNames.count)
                XCTAssertEqual(chord.pitchClasses.first, root.rawValue)
                for (pc, name) in zip(chord.pitchClasses, chord.noteNames) {
                    let natural = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(name.prefix(1))]!
                    let adjustment = name.dropFirst().reduce(0) { $0 + ($1 == "♯" ? 1 : $1 == "♭" ? -1 : 0) }
                    XCTAssertEqual((natural + adjustment + 12) % 12, pc)
                }
                XCTAssertEqual(try JSONDecoder().decode(ChordDefinition.self, from: JSONEncoder().encode(chord)), chord)
            }
        }
        XCTAssertEqual(ChordDefinition(root: .f, kind: .suspended4).noteNames, ["F", "B♭", "C"])
        XCTAssertEqual(ChordDefinition(root: .cSharp, kind: .major).noteNames, ["C♯", "E♯", "G♯"])
        XCTAssertEqual(ChordDefinition(root: .c, kind: .diminished7).noteNames, ["C", "E♭", "G♭", "B♭♭"])
        XCTAssertEqual(ChordDefinition(root: .c, kind: .augmented).noteNames, ["C", "E", "G♯"])
        XCTAssertEqual(ChordDefinition(root: .c, kind: .dominant9).degrees, ["1", "3", "5", "♭7", "9"])
    }

    func testEnumerationMatchesIndependentBruteForceWithoutBarresOrResultCap() throws {
        // Independent product of all six strings, including out-of-chord positions.
        // This reference has no search pruning or chord-library fingering helper.
        let chord = ChordDefinition(root: .c, kind: .major)
        let options = ChordSearchOptions(maximumFret: 3, maximumSpan: 2, maximumStrings: 5, allowBarre: false)
        let actual = try ChordLibrary.voicings(for: chord, options: options)
        var expected = Set<[Int?]>()
        var tuple = [Int?](repeating: nil, count: 6)
        func enumerate(_ string: Int) {
            if string == 6 {
                let sounding = tuple.compactMap { $0 }.count
                guard (3...5).contains(sounding) else { return }
                let pressed = tuple.compactMap { $0 }.filter { $0 > 0 }
                guard pressed.count <= 4, (pressed.max() ?? 0) - (pressed.min() ?? 0) <= 2 else { return }
                let pcs = Set((0..<6).compactMap { s in tuple[s].map { (MusicTheory.standardTuning[s] + $0) % 12 } })
                if pcs == Set([0, 4, 7]) { expected.insert(tuple) }
                return
            }
            for value in -1...3 { tuple[string] = value < 0 ? nil : value; enumerate(string + 1) }
        }
        enumerate(0)
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(Set(actual.map(\.frets)), expected)
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertEqual(try ChordLibrary.voicings(for: chord, options: options), actual)
    }

    func testEveryReturnedCandidateHasAllTonesAndLegalFingerContacts() throws {
        var representedKinds = Set<ChordKind>()
        for root in PitchClass.allCases {
            for kind in ChordKind.allCases {
                let chord = ChordDefinition(root: root, kind: kind)
                let options = ChordSearchOptions(maximumFret: 5, maximumSpan: 4)
                let results = try ChordLibrary.voicings(for: chord, options: options)
                if !results.isEmpty { representedKinds.insert(kind) }
                if [.major, .minor, .dominant7].contains(kind) { XCTAssertFalse(results.isEmpty, chord.name) }
                XCTAssertEqual(Set(results.map(\.id)).count, results.count, chord.name)
                for voicing in results {
                    XCTAssertEqual(Set(voicing.midiNotes.map { $0 % 12 }), Set(chord.pitchClasses), chord.name)
                    XCTAssertLessThanOrEqual(voicing.fingerCount, 4)
                    XCTAssertLessThanOrEqual(voicing.fretSpan, 4)
                    XCTAssertEqual(voicing.notes.map(\.string), voicing.notes.map(\.string).sorted(by: >))
                    XCTAssertEqual(voicing.positions.count, 6)
                    let groups = Dictionary(grouping: (0..<6).filter { (voicing.frets[$0] ?? 0) > 0 }, by: { voicing.fingers[$0]! })
                    XCTAssertEqual(groups.count, voicing.fingerCount)
                    for (finger, strings) in groups {
                        XCTAssertTrue((1...4).contains(finger))
                        let fret = voicing.frets[strings[0]]!
                        XCTAssertTrue(strings.allSatisfy { voicing.frets[$0] == fret })
                        if strings.count > 1 {
                            let barre = try XCTUnwrap(voicing.barres.first { $0.finger == finger })
                            XCTAssertEqual(barre.fret, fret)
                            XCTAssertEqual(barre.fromString, strings.min()! + 1)
                            XCTAssertEqual(barre.toString, strings.max()! + 1)
                            for string in barre.fromString...barre.toString {
                                XCTAssertGreaterThanOrEqual(voicing.frets[string - 1] ?? -1, barre.fret)
                            }
                        }
                    }
                    for string in 0..<6 {
                        if voicing.frets[string] == nil { XCTAssertNil(voicing.fingers[string]) }
                        if voicing.frets[string] == 0 { XCTAssertEqual(voicing.fingers[string], 0) }
                    }
                }
            }
        }
        XCTAssertEqual(representedKinds, Set(ChordKind.allCases))
    }

    func testKnownOpenAndBarreChordsRespectFingerBudget() throws {
        let c = ChordDefinition(root: .c, kind: .major)
        let openC: [Int?] = [0, 1, 0, 2, 3, nil]
        let results = try ChordLibrary.voicings(for: c, options: .init(maximumFret: 5, rootInBass: true))
        let open = try XCTUnwrap(results.first { $0.frets == openC })
        XCTAssertEqual(open.fingerCount, 3)
        XCTAssertTrue(open.barres.isEmpty)

        let f = ChordDefinition(root: .f, kind: .major)
        let fullF: [Int?] = [1, 1, 2, 3, 3, 1]
        let full = try XCTUnwrap(ChordLibrary.voicings(for: f, options: .init(maximumFret: 3, maximumSpan: 2, minimumStrings: 6)).first { $0.frets == fullF })
        XCTAssertTrue(full.barres.contains { $0.fret == 1 && $0.fromString == 1 && $0.toString == 6 })
        XCTAssertLessThanOrEqual(full.fingerCount, 4)
        let noBarres = try ChordLibrary.voicings(for: f, options: .init(maximumFret: 3, maximumSpan: 2, minimumStrings: 6, allowBarre: false))
        XCTAssertFalse(noBarres.contains { $0.frets == fullF }, "Six pressed strings cannot use six separate fingers")

        let movableC: [Int?] = [3, 5, 5, 5, 3, nil]
        let twoFinger = try XCTUnwrap(ChordLibrary.voicings(for: c, options: .init(minimumFret: 3, maximumFret: 5, maximumFingers: 2)).first { $0.frets == movableC })
        XCTAssertEqual(twoFinger.fingerCount, 2)
        XCTAssertEqual(twoFinger.barres.count, 2)
    }

    func testOpenMutedAndLowerFretsNeverBecomeFalseBarres() throws {
        let c = ChordDefinition(root: .c, kind: .major)
        let splitThirdFret: [Int?] = [3, 1, 0, 2, 3, nil]
        let four = try XCTUnwrap(ChordLibrary.voicings(for: c, options: .init(maximumFret: 3)).first { $0.frets == splitThirdFret })
        XCTAssertEqual(four.fingerCount, 4)
        XCTAssertTrue(four.barres.isEmpty)
        XCTAssertFalse(try ChordLibrary.voicings(for: c, options: .init(maximumFret: 3, maximumFingers: 3)).contains { $0.frets == splitThirdFret })

        let g = ChordDefinition(root: .g, kind: .major)
        let openG: [Int?] = [3, 0, 0, 0, 2, 3]
        let candidate = try XCTUnwrap(ChordLibrary.voicings(for: g, options: .init(maximumFret: 3)).first { $0.frets == openG })
        XCTAssertEqual(candidate.fingerCount, 3)
        XCTAssertTrue(candidate.barres.isEmpty)
    }

    func testRootBassUsesActualPitchRatherThanLowestNumberedString() throws {
        let chord = ChordDefinition(root: .g, kind: .suspended2)
        // Sixth string G3 lies above the fifth string's open A2.
        let crossing: [Int?] = [nil, nil, 0, 0, 0, 15]
        var options = ChordSearchOptions(minimumFret: 15, maximumFret: 15, maximumSpan: 0, maximumStrings: 4, maximumFingers: 1)
        let candidate = try XCTUnwrap(ChordLibrary.voicings(for: chord, options: options).first { $0.frets == crossing })
        XCTAssertEqual(candidate.bassMIDI, 45)
        XCTAssertEqual(candidate.fretSpan, 0, "Open strings are independent of the fretted span")
        options.rootInBass = true
        XCTAssertFalse(try ChordLibrary.voicings(for: chord, options: options).contains { $0.frets == crossing })
        options.rootInBass = false; options.allowOpenStrings = false
        XCTAssertFalse(try ChordLibrary.voicings(for: chord, options: options).contains { $0.frets == crossing })
    }

    func testSeventhAndNinthDoNotSilentlyOmitDefiningOrOtherChordTones() throws {
        let openC: [Int?] = [0, 1, 0, 2, 3, nil]
        let seventh = try ChordLibrary.voicings(for: .init(root: .c, kind: .dominant7), options: .init(maximumFret: 5))
        XCTAssertFalse(seventh.contains { $0.frets == openC })
        let ninth = ChordDefinition(root: .c, kind: .dominant9)
        XCTAssertTrue(try ChordLibrary.voicings(for: ninth, options: .init(maximumFret: 5, maximumStrings: 4)).isEmpty)
        let complete = try ChordLibrary.voicings(for: ninth, options: .init(maximumFret: 5, rootInBass: true))
        XCTAssertTrue(complete.contains { $0.frets == [3, 3, 3, 2, 3, nil] })
        XCTAssertTrue(complete.allSatisfy { Set($0.midiNotes.map { $0 % 12 }) == Set([0, 2, 4, 7, 10]) })
    }

    func testInvalidBoundsAndCancellationDoNotProduceMisleadingPartialResults() throws {
        let chord = ChordDefinition(root: .c, kind: .major)
        let invalid: [ChordSearchOptions] = [
            .init(minimumFret: 0), .init(minimumFret: 25), .init(minimumFret: 6, maximumFret: 5),
            .init(maximumFret: Int.max), .init(maximumSpan: -1), .init(maximumSpan: Int.max),
            .init(minimumStrings: 0), .init(minimumStrings: 7), .init(minimumStrings: 5, maximumStrings: 4),
            .init(maximumFingers: 5), .init(maximumFingers: -1)
        ]
        for options in invalid { XCTAssertThrowsError(try ChordLibrary.voicings(for: chord, options: options)) }
        XCTAssertThrowsError(try ChordLibrary.voicings(for: chord, isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        var checks = 0
        XCTAssertThrowsError(try ChordLibrary.voicings(for: chord, options: .init(maximumFret: 24, maximumSpan: 23), isCancelled: {
            checks += 1; return checks >= 2
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThanOrEqual(checks, 2)
    }

    func testDefaultRecommendationsPreferContiguousRootPositionBeginnerShapes() throws {
        let c = try ChordLibrary.voicings(for: .init(root: .c, kind: .major))
        XCTAssertEqual(c.count, 470, "Native QA's complete default result count must survive the ranking change")
        XCTAssertEqual(c.first?.frets, [0, 1, 0, 2, 3, nil]) // x32010
        let withRootBass = try ChordLibrary.voicings(for: .init(root: .c, kind: .major), options: .init(rootInBass: true))
        XCTAssertEqual(withRootBass.first?.frets, [0, 1, 0, 2, 3, nil])
        XCTAssertEqual(Set(withRootBass.map(\.id)), Set(c.filter { $0.bassMIDI % 12 == 0 }.map(\.id)))
        let e = try ChordLibrary.voicings(for: .init(root: .e, kind: .major))
        XCTAssertEqual(e.first?.frets, [0, 0, 1, 2, nil, nil]) // xx2100, root-position compact E
        let g = try ChordLibrary.voicings(for: .init(root: .g, kind: .major))
        XCTAssertEqual(g.first?.frets, [nil, 0, 0, 0, 2, 3]) // 32000x, complete G with two fingers
        XCTAssertTrue(g.contains { $0.frets == [3, 0, 0, 0, 2, 3] }, "The standard six-string 320003 remains available")
        // Sparse inversions are still available, but no longer lead the page or drill deck.
        let sparseC: [Int?] = [0, 1, 0, nil, nil, 0]
        XCTAssertTrue(c.contains { $0.frets == sparseC })
        XCTAssertNotEqual(c.first?.frets, sparseC)
    }

    func testSharedGripValidatorChecksTheWholeSimultaneousHand() {
        XCTAssertFalse(ChordLibrary.canFinger(frets: [3, 1, 3, 2, 3, nil]), "x32313 needs five fingers separated by lower frets")
        XCTAssertTrue(ChordLibrary.canFinger(frets: [3, 5, 3, 5, 3, nil]), "x35353 is a complete C7 with legal third-fret barre")
        XCTAssertFalse(ChordLibrary.canFinger(frets: [3, 4, 3, 1, 6, nil]), "Check the bass as well as the upper strings")
        XCTAssertTrue(ChordLibrary.canFinger(frets: [0, 0, 0, 0, 0, 0], maximumSpan: 0, maximumFingers: 0))
        XCTAssertFalse(ChordLibrary.canFinger(frets: [0, 0, 1, 0, 0, 0], maximumFingers: 0))
        XCTAssertFalse(ChordLibrary.canFinger(frets: [nil]))
        XCTAssertFalse(ChordLibrary.canFinger(frets: [nil, nil, nil, nil, nil, Int.max]))
        XCTAssertFalse(ChordLibrary.canFinger(frets: [nil, nil, nil, nil, nil, -1]))
        XCTAssertFalse(ChordLibrary.canFinger(frets: [0, 0, 0, 0, 0, 0], maximumSpan: -1))
        XCTAssertFalse(ChordLibrary.canFinger(frets: [0, 0, 0, 0, 0, 0], maximumFingers: 5))
    }
}
