import XCTest
@testable import GuitarCore

final class ScoreChordSymbolTests: XCTestCase {
    private func roman(_ text: String, tonic: PitchClass = .c, minor: Bool = false) throws -> String {
        try XCTUnwrap(ScoreChordSymbol(text), "Expected a valid chord: \(text)").romanNumeral(tonic: tonic, minor: minor)
    }

    func testCommonSymbolsAndSpelledAccidentalsParseAsCompleteLabels() throws {
        let examples: [(String, Int)] = [("C", 0), ("Am", 9), ("Fmaj7", 5), ("Bb", 10), ("B♭", 10),
                                        ("F#dim", 6), ("F♯dim7", 6), ("C/G", 0), ("Em7", 4), ("Dsus2", 2),
                                        ("Gsus4", 7), ("A7", 9), ("D9", 2), ("G6", 7), ("Cadd9", 0),
                                        ("Bø7", 11), ("Bm7b5", 11), ("C6/9", 0), ("C6/9/E", 0), ("C♮", 0)]
        for (text, expected) in examples {
            let symbol = try XCTUnwrap(ScoreChordSymbol(text), text)
            XCTAssertEqual(symbol.rootPitchClass, expected, text)
            XCTAssertEqual(symbol.text, text)
        }
    }

    func testTrimsOnlyOuterWhitespaceAndPreservesDisplaySpelling() throws {
        XCTAssertEqual(try XCTUnwrap(ScoreChordSymbol(" \tB♭maj7/F\n ")).text, "B♭maj7/F")
        XCTAssertEqual(try XCTUnwrap(ScoreChordSymbol("CM7")).text, "CM7")
        XCTAssertEqual(try XCTUnwrap(ScoreChordSymbol("C-7")).text, "C-7")
        for text in ["C maj7", "C / G", "A m", "C\nG"] { XCTAssertNil(ScoreChordSymbol(text), text) }
    }

    func testOrdinaryLyricsAndUnknownExtensionsAreNotRecognized() {
        for text in ["", " ", "love", "Amor", "Bridge", "Dancing", "Good", "Come", "Coda", "Am I",
                     "A beautiful day", "C’est", "[Am]", "(Am)", "歌词", "C/歌词", "Cmajorly", "Cfoo7", "Cmaj99",
                     "C7(hello)", "C7#7", "Csus3", "CnoIdea", "C?", "N.C.", "am", "b", "H7"] {
            XCTAssertNil(ScoreChordSymbol(text), "Must preserve non-chord text: \(text)")
        }
    }

    func testMajorScaleDegreesAndBorrowedMinorQuality() throws {
        let expected = ["C": "I", "Dm": "ii", "Em7": "iii7", "Fmaj7": "IVmaj7", "G7": "V7",
                        "Am": "vi", "Bdim": "vii°", "Fm": "iv", "Bb": "♭VII", "E": "III"]
        for (symbol, degree) in expected { XCTAssertEqual(try roman(symbol), degree, symbol) }
        XCTAssertEqual(try roman("Bb", tonic: .f), "IV")
        XCTAssertEqual(try roman("B♭maj7", tonic: .f), "IVmaj7")
    }

    func testNaturalMinorDegreesDoNotReuseMajorFlatDegreeLabels() throws {
        let expected = ["Em": "i", "F#dim": "ii°", "G": "III", "Am": "iv", "Bm": "v", "C": "VI", "D": "VII", "B7": "V7"]
        for (symbol, degree) in expected { XCTAssertEqual(try roman(symbol, tonic: .e, minor: true), degree, symbol) }
        XCTAssertEqual(try roman("G#dim7", tonic: .a, minor: true), "♯vii°7")
        XCTAssertEqual(try roman("E", minor: true), "♯III")
        XCTAssertEqual(try roman("Ab", minor: true), "VI")
    }

    func testEnharmonicRootsKeepTheirLetterBasedDegree() throws {
        XCTAssertEqual(try roman("F#"), "♯IV")
        XCTAssertEqual(try roman("Gb"), "♭V")
        XCTAssertEqual(try roman("C#"), "♯I")
        XCTAssertEqual(try roman("Db"), "♭II")
        XCTAssertEqual(try roman("B#"), "♯VII")
        XCTAssertEqual(try roman("Cb"), "♭I")
        XCTAssertEqual(try roman("F##dim"), "♯♯iv°")
        XCTAssertEqual(try roman("Gbb"), "♭♭V")
        XCTAssertEqual(try roman("Bb", tonic: .cSharp), "♭♭VII")
    }

    func testAllTwelveTonicsUseTheirActualMajorAndMinorSpelling() throws {
        for tonic in PitchClass.allCases {
            for minor in [false, true] {
                let names = MusicTheory.spelledNotes(root: tonic, kind: minor ? .naturalMinor : .major)
                for (index, name) in names.enumerated() {
                    XCTAssertEqual(try roman(name, tonic: tonic, minor: minor), ["I", "II", "III", "IV", "V", "VI", "VII"][index], "\(tonic) \(minor) \(name)")
                }
            }
        }
    }

    func testSlashBassIsPreservedWithoutInventingFiguredBass() throws {
        XCTAssertEqual(try roman("C/E"), "I/E")
        XCTAssertEqual(try roman("C/G"), "I/G")
        XCTAssertEqual(try roman("Am/G"), "vi/G")
        XCTAssertEqual(try roman("Fmaj7/A", tonic: .f), "Imaj7/A")
        XCTAssertEqual(try roman("Bb/D", tonic: .f), "IV/D")
        XCTAssertEqual(try roman("C7/B♭"), "I7/B♭")
        XCTAssertEqual(try roman("C6/9/E"), "I6/9/E")
        for text in ["C/", "C//G", "C/G/B", "C/Em", "C/G7", "C/E4", "C7/9", "C6/9/E/G"] { XCTAssertNil(ScoreChordSymbol(text), text) }
    }

    func testMinorMajorDiminishedAugmentedAndHalfDiminishedQualities() throws {
        let expected = ["Cm": "i", "Cmin7": "i7", "C-9": "i9", "CM7": "Imaj7", "CΔ7": "Imaj7",
                        "CmMaj7": "imaj7", "Cm(maj7)": "imaj7", "CmM9": "imaj9", "Cdim": "i°", "Co7": "i°7",
                        "C°7": "i°7", "Caug": "I+", "C+7": "I+7", "Cø": "iø7", "Cø7": "iø7",
                        "Cm7b5": "iø7", "Cm7(♭5)": "iø7", "Cmin7b5": "iø7"]
        for (symbol, degree) in expected { XCTAssertEqual(try roman(symbol), degree, symbol) }
    }

    func testSuspensionsAddedNotesAndKnownAlteredExtensions() throws {
        let expected = ["Csus": "Isus4", "Csus2": "Isus2", "Csus4": "Isus4", "C7sus4": "I7sus4",
                        "C9": "I9", "C6": "I6", "C5": "I5", "C69": "I6/9", "Cadd9": "Iadd9",
                        "Cmadd9": "iadd9", "C(add9)": "Iadd9", "C7b9": "I7♭9", "C7(#9)": "I7♯9",
                        "Cmaj7#11": "Imaj7♯11", "Cm9b13": "i9♭13"]
        for (symbol, degree) in expected { XCTAssertEqual(try roman(symbol), degree, symbol) }
    }

    func testMalformedAccidentalsAndPunctuationCannotBecomeChordLabels() {
        for text in ["#C", "C#b", "Cb#", "C###", "Cbbb", "C♮#", "Cmaj7.", "A,m", "D：", "C7()", "C7((b9))", "C7(b9", "C7b9)"] {
            XCTAssertNil(ScoreChordSymbol(text), text)
        }
    }
}
