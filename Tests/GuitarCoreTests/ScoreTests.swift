import XCTest
@testable import GuitarCore

final class ScoreTests: XCTestCase {
    func polyphony() -> GuitarScore {
        let melody = (0..<8).map { ScoreEvent(startTick: $0 * 480, rhythm: Rhythm(.eighth), notes: [GuitarNote(string: 1, fret: $0 % 4)]) }
        let bass = [ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [GuitarNote(string: 6, fret: 0)])]
        return GuitarScore(title: "整小节低音与八个八分旋律音", measures: [ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: melody), VoiceTrack(voice: .bass, events: bass)])])
    }
    func testDurationsAndMeters() {
        XCTAssertEqual(NoteValue.allCases.map(\.ticks), [3840,1920,960,480,240,120])
        XCTAssertEqual(Rhythm(.quarter, dotted: true).ticks, 1440)
        XCTAssertEqual(Rhythm(.eighth, triplet: true).ticks, 320)
        XCTAssertEqual(Rhythm(.eighth, triplet: true).ticks * 3, 960)
        XCTAssertEqual(TimeSignature.supported.map(\.ticks), [1920,2880,3840,2880])
    }
    func testFingerstylePolyphonyAndVoiceAlignment() {
        let score = polyphony()
        XCTAssertEqual(ScoreValidator.validate(score), [])
        let notes = ScoreScheduler.notes(score)
        XCTAssertEqual(notes.count, 9)
        XCTAssertEqual(notes.filter { $0.voice == .bass }.map(\.durationTicks), [3840])
        XCTAssertEqual(notes.filter { $0.voice == .melody }.map(\.startTick), [0,480,960,1440,1920,2400,2880,3360])
        XCTAssertEqual(notes.filter { $0.startTick <= 1000 && $0.endTick > 1000 }.count, 2)
    }
    func testCapacityAndSameStringConflictsDoNotMutateScore() {
        var score = polyphony()
        score.measures[0].voices[0].events[0].notes[0].string = 6
        let snapshot = score
        XCTAssertTrue(ScoreValidator.validate(score).contains { $0.message.contains("另一声部冲突") })
        XCTAssertEqual(score, snapshot)
        score.measures[0].voices[0].events[0].startTick = 3800
        XCTAssertTrue(ScoreValidator.validate(score).contains { $0.message.contains("容量") })
        score.measures[0].voices[0].events[0].rhythm.triplet = true
        score.measures[0].voices[0].events[0].rhythm.dotted = true
        XCTAssertTrue(ScoreValidator.validate(score).contains { $0.message.contains("不能同时") })
    }
    func testCrossMeasurePerNoteTies() {
        let held = GuitarNote(string: 6, fret: 0, tieToNext: true)
        let first = ScoreMeasure(voices: [VoiceTrack(voice: .melody), VoiceTrack(voice: .bass, events: [ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [held, GuitarNote(string: 5, fret: 2)])])])
        let next = GuitarNote(string: 6, fret: 0)
        let second = ScoreMeasure(voices: [VoiceTrack(voice: .melody), VoiceTrack(voice: .bass, events: [ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [next])])])
        let score = GuitarScore(measures: [first,second])
        XCTAssertEqual(ScoreValidator.validate(score), [])
        let notes = ScoreScheduler.notes(score)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.first { $0.note.string == 6 }?.endTick, 7680)
        XCTAssertEqual(notes.first { $0.note.string == 6 }?.continuationIDs, [next.id])
        XCTAssertEqual(notes.first { $0.note.string == 5 }?.endTick, 3840)
    }
    func testUnconnectedTieRemainsEditableWithWarning() {
        var score = GuitarScore()
        score.measures[0].voices[0].events = [ScoreEvent(startTick: 0, notes: [GuitarNote(string: 1, fret: 0, tieToNext: true)])]
        XCTAssertEqual(ScoreValidator.validate(score).first?.severity, .warning)
        XCTAssertNoThrow(try ScoreIO.encode(score))
    }
    func testRestGaps() {
        let measure = ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: [ScoreEvent(startTick: 960, notes: [GuitarNote(string: 1, fret: 0)])]), VoiceTrack(voice: .bass)])
        XCTAssertEqual(ScoreScheduler.restGaps(in: measure, voice: .melody, capacity: 3840), [TickRange(0,960),TickRange(1920,3840)])
        XCTAssertEqual(ScoreScheduler.restGaps(in: measure, voice: .bass, capacity: 3840), [TickRange(0,3840)])
    }
    func testVersionedJSONRoundTripAndInvalidInput() throws {
        let score = polyphony(), data = try ScoreIO.encode(polyphony())
        let decoded = try ScoreIO.decode(ScoreIO.encode(score))
        XCTAssertEqual(score, decoded)
        XCTAssertThrowsError(try ScoreIO.decode(Data("{broken".utf8)))
        var unsupported = score; unsupported.version = 999
        XCTAssertThrowsError(try ScoreIO.decode(JSONEncoder().encode(unsupported)))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("startTick"))
        var hostile = score; hostile.timeSignature = TimeSignature(Int.max,1); hostile.measures[0].voices[0].events[0].startTick = Int.max
        XCTAssertThrowsError(try ScoreIO.decode(JSONEncoder().encode(hostile)))
        hostile = score; hostile.measures.append(ScoreMeasure()); hostile.measures[1].voices[0].events = [ScoreEvent(startTick: Int.max, notes: [GuitarNote(string: 1, fret: 0)])]
        XCTAssertThrowsError(try ScoreIO.decode(JSONEncoder().encode(hostile)))
    }
    func testUndoRedoAndAtomicRejection() throws {
        var history = ScoreHistory(polyphony())
        let original = history.score
        try history.perform { $0.title = "编辑后" }
        XCTAssertEqual(history.score.title, "编辑后")
        history.undo(); XCTAssertEqual(history.score, original)
        history.redo(); XCTAssertEqual(history.score.title, "编辑后")
        XCTAssertThrowsError(try history.perform { $0.measures[0].voices[0].events[0].notes[0].string = 6 })
        XCTAssertEqual(history.score.measures, original.measures)
        history.undo(); try history.perform { $0.bpm = 120 }; XCTAssertFalse(history.canRedo)
    }
}
