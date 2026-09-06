import XCTest
@testable import GuitarCore

final class ScoreLyricsTests: XCTestCase {
    func testOldVersionOneEventsDecodeWithoutLyrics() throws {
        let source = """
        {"id":"E248F013-BF1D-4CE1-BB88-F68BCCF11002","startTick":0,
         "rhythm":{"value":4,"dotted":false,"triplet":false},"notes":[]}
        """
        let event = try JSONDecoder().decode(ScoreEvent.self, from: Data(source.utf8))
        XCTAssertNil(event.lyric)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
        XCTAssertNil(encoded["lyric"])
        var nullLyric = encoded
        nullLyric["lyric"] = NSNull()
        XCTAssertNil(try JSONDecoder().decode(ScoreEvent.self, from: JSONSerialization.data(withJSONObject: nullLyric)).lyric)

        let score = GuitarScore(measures: [ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: [event]), VoiceTrack(voice: .bass)])])
        XCTAssertEqual(try ScoreIO.decode(ScoreIO.encode(score)), score)
    }

    func testUnicodeLyricsOnNotesChordsAndRestsRoundTrip() throws {
        let melody = [
            ScoreEvent(startTick: 0, notes: [GuitarNote(string: 1, fret: 0), GuitarNote(string: 2, fret: 1)], lyric: "一 起"),
            ScoreEvent(startTick: 960, notes: [GuitarNote(string: 1, fret: 1)], lyric: "sing — softly"),
            ScoreEvent(startTick: 1920, notes: [], lyric: "换气\n再唱")
        ]
        let score = GuitarScore(measures: [ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: melody), VoiceTrack(voice: .bass)])])
        let reopened = try ScoreIO.decode(ScoreIO.encode(score))
        XCTAssertEqual(reopened, score)
        XCTAssertEqual(reopened.version, 1)
        XCTAssertEqual(reopened.measures[0].events(for: .melody).map(\.lyric), ["一 起", "sing — softly", "换气\n再唱"])
    }

    func testLyricEditUndoAndRemovalDoNotAffectScheduledNotes() throws {
        let event = ScoreEvent(startTick: 0, notes: [GuitarNote(string: 1, fret: 3)])
        let original = GuitarScore(measures: [ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: [event]), VoiceTrack(voice: .bass)])])
        var history = ScoreHistory(original)
        try history.perform { $0.measures[0].voices[0].events[0].lyric = "la" }
        XCTAssertEqual(history.score.measures[0].voices[0].events[0].lyric, "la")
        XCTAssertFalse(history.score.hasSameContent(as: original))
        XCTAssertEqual(ScoreScheduler.notes(history.score).map(\.note), ScoreScheduler.notes(original).map(\.note))
        XCTAssertEqual(ScoreScheduler.notes(history.score).map(\.durationTicks), ScoreScheduler.notes(original).map(\.durationTicks))
        history.undo()
        XCTAssertEqual(history.score, original)
        history.redo()
        XCTAssertEqual(history.score.measures[0].voices[0].events[0].lyric, "la")
        try history.perform { $0.measures[0].voices[0].events[0].lyric = nil }
        XCTAssertEqual(history.score, original)
    }

}
