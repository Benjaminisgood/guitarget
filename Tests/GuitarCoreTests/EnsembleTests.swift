import XCTest
@testable import GuitarCore

final class EnsembleTests: XCTestCase {
    func testEveryArrangementInEveryKeyIsValidAndVoicesUseSeparateStrings() {
        for root in PitchClass.allCases { for style in JamStyle.allCases {
            let jam = JamBuilder.make(root: root, style: style)
            XCTAssertEqual(ScoreValidator.validate(jam.score), [], "\(root) \(style)")
            XCTAssertEqual(jam.chords.count, style == .blues ? 12 : 4)
            for measure in jam.score.measures {
                XCTAssertTrue(measure.events(for: .melody).flatMap(\.notes).allSatisfy { (1...4).contains($0.string) })
                XCTAssertTrue(measure.events(for: .bass).flatMap(\.notes).allSatisfy { (5...6).contains($0.string) })
                let events = measure.voices.flatMap(\.events)
                for tick in Set(events.map(\.startTick)) {
                    let sounding = events.filter { $0.startTick <= tick && $0.endTick > tick }.flatMap(\.notes)
                    var frets = [Int?](repeating: nil, count: 6)
                    for note in sounding { frets[note.string - 1] = note.fret }
                    XCTAssertTrue(ChordLibrary.canFinger(frets: frets, maximumSpan: 4), "\(root) \(style) at \(tick): \(frets)")
                }
            }
        } }
    }

    func testChordRecommendationsFollowThePlaybackMeasureAndKeySpelling() {
        let jam = JamBuilder.make(root: .f, style: .folk)
        XCTAssertEqual(jam.chord(atTick: 0).name, "F")
        XCTAssertEqual(jam.chord(atTick: 3840).name, "C")
        XCTAssertEqual(jam.chord(atTick: 3 * 3840).name, "B♭")
        XCTAssertEqual(jam.chord(atTick: -960).measure, 0)
        XCTAssertEqual(jam.chord(atTick: Int.max).measure, 3)
        let positions = jam.recommendations(atTick: 3 * 3840, mode: .chordTones)
        XCTAssertEqual(Set(positions.map(\.name)), Set(["B♭","D","F"]))
        XCTAssertEqual(Set(positions.map(\.pitchClass)), Set([10,2,5]))
        XCTAssertTrue(positions.filter(\.isRoot).allSatisfy { $0.pitchClass == 10 })
        let notes = jam.recommendations(atTick: 0, mode: .keyScale)
        XCTAssertTrue(notes.contains { $0.name == "B♭" })
        XCTAssertFalse(notes.contains { $0.name == "A♯" })
        let sharpKey = JamBuilder.make(root: .cSharp, style: .folk)
        XCTAssertTrue(sharpKey.recommendations(atTick: 0, mode: .chordTones).contains { $0.name == "E♯" })
        XCTAssertTrue(sharpKey.recommendations(atTick: 0, mode: .keyScale).contains { $0.name == "B♯" })
    }

    func testHarmonyCoversEachChordAndExportRoundTrips() throws {
        for style in JamStyle.allCases {
            let jam = JamBuilder.make(root: .a, style: style)
            for (index, measure) in jam.score.measures.enumerated() {
                let sounded = Set(measure.events(for: .melody).flatMap(\.notes).map { jam.score.midi(for: $0) % 12 })
                XCTAssertEqual(sounded, Set(jam.chords[index].pitchClasses))
            }
            let data = try JSONEncoder().encode(jam.score)
            XCTAssertEqual(try JSONDecoder().decode(GuitarScore.self, from: data), jam.score)
        }
    }

    func testTempoAndRecommendationRangeAreBounded() {
        XCTAssertEqual(JamBuilder.make(root: .c, style: .folk, bpm: .nan).score.bpm, 80)
        XCTAssertEqual(JamBuilder.make(root: .c, style: .folk, bpm: 1).score.bpm, 40)
        let jam = JamBuilder.make(root: .a, style: .blues)
        let pentatonic = jam.recommendations(atTick: 0, mode: .pentatonic, maxFret: 12)
        XCTAssertEqual(Set(pentatonic.map(\.pitchClass)), Set([9,0,2,4,7]))
        XCTAssertTrue(pentatonic.allSatisfy { $0.fret <= 12 })
        XCTAssertTrue(jam.recommendations(atTick: 0, mode: .keyScale).contains { $0.isBlue })
    }
}
