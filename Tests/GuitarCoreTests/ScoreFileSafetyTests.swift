import XCTest
@testable import GuitarCore

final class ScoreFileSafetyTests: XCTestCase {
    private func document() -> GuitarScore {
        var score = GuitarScore()
        score.measures[0].voices[0].events = [ScoreEvent(startTick: 0, notes: [GuitarNote(string: 1, fret: 0)])]
        return score
    }
    private func encoded(_ score: GuitarScore) throws -> Data { try JSONEncoder().encode(score) }
    private func assertRejected(_ score: GuitarScore, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try encoded(score)
        XCTAssertThrowsError(try ScoreIO.decode(data), file: file, line: line)
        XCTAssertThrowsError(try ScoreIO.encode(score), file: file, line: line)
        XCTAssertFalse(ScoreValidator.validate(score).filter { $0.severity == .error }.isEmpty, file: file, line: line)
        XCTAssertTrue(PracticeTarget.from(score: score, voice: .melody).isEmpty, file: file, line: line)
    }
    func testUntrustedMeterIntegerBoundsRejectBeforeCapacityArithmetic() throws {
        for extreme in [Int.min,Int.max,-1,0,Int.max / 3840 + 1] {
            var score = document(); score.timeSignature = TimeSignature(extreme,4)
            XCTAssertEqual(score.timeSignature.ticks, 0)
            try assertRejected(score)
            score.timeSignature = TimeSignature(4,extreme)
            XCTAssertEqual(score.timeSignature.ticks, 0)
            try assertRejected(score)
        }
        var score = document(); score.timeSignature = TimeSignature(32,1)
        try assertRejected(score)
    }
    func testTickBoundsAtFirstAndLaterMeasuresNeverOverflow() throws {
        for extreme in [Int.min,Int.max,Int.max - 100,-1,3840] {
            for measure in [0,1] {
                var score = document(); score.measures.append(ScoreMeasure())
                score.measures[measure].voices[0].events = [ScoreEvent(startTick: extreme, notes: [GuitarNote(string: 1, fret: 0)])]
                try assertRejected(score)
                XCTAssertTrue(ScoreScheduler.notes(score).allSatisfy { $0.startTick >= 0 && $0.endTick <= score.totalTicks })
            }
        }
        XCTAssertEqual(ScoreEvent(startTick: Int.max).endTick, Int.max)
        XCTAssertEqual(ScoreEvent(startTick: Int.min).endTick, Int.min + 960)
        XCTAssertEqual(TickRange(Int.min,Int.max).ticks, Int.max)
        XCTAssertEqual(TickRange(Int.max,Int.min).ticks, Int.min)
        XCTAssertEqual(ScoreScheduler.restGaps(in: ScoreMeasure(), voice: .melody, capacity: Int.min), [])
    }
    func testStringFretTargetAndTuningIntegerBoundsRejectWithoutIndexing() throws {
        for extreme in [Int.min,Int.max,-1,128] {
            var score = document(); score.tuning[0] = extreme; try assertRejected(score)
            XCTAssertNil(score.validMIDI(for: score.measures[0].voices[0].events[0].notes[0]))
            score = document(); score.measures[0].voices[0].events[0].notes[0].string = extreme; try assertRejected(score)
            XCTAssertEqual(score.midi(for: score.measures[0].voices[0].events[0].notes[0]), -1)
            score = document(); score.measures[0].voices[0].events[0].notes[0].fret = extreme; try assertRejected(score)
            score = document(); score.measures[0].voices[0].events[0].notes[0].targetFret = extreme; try assertRejected(score)
        }
        var score = document(); score.tuning = []; try assertRejected(score)
    }
    func testActualAndTechniquePitchRemainInMIDIDomain() throws {
        var score = document(); score.tuning[0] = 127
        XCTAssertNoThrow(try ScoreIO.encode(score))
        score.measures[0].voices[0].events[0].notes[0].fret = 24; try assertRejected(score)
        score.measures[0].voices[0].events[0].notes[0].fret = 0
        score.measures[0].voices[0].events[0].notes[0].technique = .bendHalf; try assertRejected(score)
        score.measures[0].voices[0].events[0].notes[0].technique = .slide
        score.measures[0].voices[0].events[0].notes[0].targetFret = 1; try assertRejected(score)
    }
    func testInvalidRhythmJSONAndFractionalTicksAreRejected() throws {
        let valid = String(decoding: try encoded(document()), as: UTF8.self)
        XCTAssertTrue(valid.contains("\"value\":4")); XCTAssertTrue(valid.contains("\"startTick\":0"))
        for raw in ["0","3","-1","9223372036854775807","4.5","null","\"quarter\""] {
            let malformed = valid.replacingOccurrences(of: "\"value\":4", with: "\"value\":\(raw)")
            XCTAssertThrowsError(try ScoreIO.decode(Data(malformed.utf8)))
        }
        let fractional = valid.replacingOccurrences(of: "\"startTick\":0", with: "\"startTick\":0.5")
        XCTAssertThrowsError(try ScoreIO.decode(Data(fractional.utf8)))
        var score = document(); score.measures[0].voices[0].events[0].rhythm = Rhythm(.quarter, triplet: true); try assertRejected(score)
        score.measures[0].voices[0].events[0].rhythm = Rhythm(.eighth, dotted: true, triplet: true); try assertRejected(score)
    }
    func testUnknownVersionAndNonfiniteTempoOrVelocity() throws {
        for version in [Int.min,-1,0,2,Int.max] {
            let data = Data("{\"version\":\(version)}".utf8)
            XCTAssertThrowsError(try ScoreIO.decode(data)) { error in XCTAssertTrue(error.localizedDescription.contains("不支持文档版本")) }
        }
        let valid = String(decoding: try encoded(document()), as: UTF8.self)
        for raw in ["NaN","Infinity","-Infinity","1e309","\"NaN\""] {
            let malformed = valid.replacingOccurrences(of: "\"bpm\":80", with: "\"bpm\":\(raw)")
            XCTAssertThrowsError(try ScoreIO.decode(Data(malformed.utf8)))
        }
        for value in [Double.nan,Double.infinity,-Double.infinity] {
            var score = document(); score.bpm = value
            XCTAssertThrowsError(try ScoreIO.encode(score))
            score = document(); score.measures[0].voices[0].events[0].notes[0].velocity = value
            XCTAssertThrowsError(try ScoreIO.encode(score))
        }
    }
    func testRejectedReadPreservesOriginalFileBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("guitarget-rejected-\(UUID().uuidString).guitarget")
        var score = document(); score.measures[0].voices[0].events[0].startTick = Int.max
        let original = try encoded(score)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ScoreIO.decode(Data(contentsOf: url)))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
