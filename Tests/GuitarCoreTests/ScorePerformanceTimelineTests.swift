import XCTest
@testable import GuitarCore

final class ScorePerformanceTimelineTests: XCTestCase {
    func testContextAtPhraseBoundariesAcrossMeasuresAndBackwardSeek() throws {
        let score = makeScore(melody: [(480, "你"), (1440, "好，"), (3840, "再"), (4800, "见。")])
        XCTAssertTrue(ScoreValidator.validate(score).isEmpty)
        let timeline = ScorePerformanceTimeline(score: score, voice: .melody)
        XCTAssertEqual(timeline.lyricPhrases, [
            ScoreLyricPhrase(startTick: 480, endTick: 2400, text: "你好，"),
            ScoreLyricPhrase(startTick: 3840, endTick: 5760, text: "再见。")
        ])
        let before = timeline.context(at: 479)
        XCTAssertNil(before.currentLyric)
        XCTAssertNil(before.previousLyric)
        XCTAssertEqual(before.nextLyric, timeline.lyricPhrases.first)
        XCTAssertEqual(timeline.context(at: 480).currentLyric?.text, "你好，")
        XCTAssertEqual(timeline.context(at: 2399).currentLyric?.text, "你好，")
        let gap = timeline.context(at: 2400)
        XCTAssertNil(gap.currentLyric)
        XCTAssertEqual(gap.previousLyric?.text, "你好，")
        XCTAssertEqual(gap.nextLyric?.text, "再见。")
        let second = timeline.context(at: 3840)
        XCTAssertEqual(second.previousLyric?.text, "你好，")
        XCTAssertEqual(second.currentLyric?.text, "再见。")
        XCTAssertNil(second.nextLyric)
        XCTAssertNil(timeline.context(at: 5760).currentLyric)
        XCTAssertEqual(timeline.context(at: Int.max).previousLyric?.text, "再见。")
        XCTAssertEqual(timeline.context(at: 479), before, "A backward seek must not depend on a mutable playback cursor")
        XCTAssertEqual(timeline.context(at: 3840), second, "A paused tick must give the same context on every read")
        let reopened = try ScoreIO.decode(ScoreIO.encode(score))
        XCTAssertEqual(ScorePerformanceTimeline(score: reopened, voice: .melody).lyricPhrases, timeline.lyricPhrases)
    }

    func testOneMeasureLyricSilenceSplitsButShorterSilenceDoesNot() {
        // The first quarter-note lyric ends at 960, not at its onset.
        let gap = ScorePerformanceTimeline(score: makeScore(melody: [(0, "天"), (4800, "空")]), voice: .melody)
        XCTAssertEqual(gap.lyricPhrases.map(\.text), ["天", "空"])
        XCTAssertNil(gap.context(at: 3840).currentLyric)
        XCTAssertEqual(gap.context(at: 3840).nextLyric?.startTick, 4800)
        let shorter = ScorePerformanceTimeline(score: makeScore(melody: [(0, "天"), (4680, "空")]), voice: .melody)
        XCTAssertEqual(shorter.lyricPhrases.map(\.text), ["天空"])
        XCTAssertEqual(shorter.context(at: 3840).currentLyric?.text, "天空")
    }

    func testPhrasesNeverSpanFiveMeasuresWithoutAnExplicitBoundary() {
        let entries = (0..<9).map { ($0 * 3840, "la") }
        let timeline = ScorePerformanceTimeline(score: makeScore(melody: entries), voice: .melody)
        XCTAssertEqual(timeline.lyricPhrases.map(\.startTick), [0, 15360, 30720])
        XCTAssertEqual(timeline.lyricPhrases.map(\.text), ["la la la la", "la la la la", "la"])
        for phrase in timeline.lyricPhrases {
            XCTAssertLessThan((phrase.endTick - 1) / 3840 - phrase.startTick / 3840, 4)
        }
        let threeFour = ScorePerformanceTimeline(score: makeScore(melody: (0..<5).map { ($0 * 2880, "风") }, signature: TimeSignature(3, 4)), voice: .melody)
        XCTAssertEqual(threeFour.lyricPhrases.map(\.startTick), [0, 11520], "Use the score's actual measure capacity")
    }

    func testChineseEnglishSyllablesAndPunctuationJoinWithoutInventingWordTicks() {
        let english = ScorePerformanceTimeline(score: makeScore(melody: [(0, "A-"), (960, "ma-"), (1920, "zing"), (2880, "grace!")]), voice: .melody)
        XCTAssertEqual(english.lyricPhrases.map(\.text), ["Amazing grace!"])
        XCTAssertEqual(english.lyricPhrases.first?.endTick, 3840)
        let chinese = ScorePerformanceTimeline(score: makeScore(melody: [(0, "一 起"), (960, "唱，"), (1920, "再"), (2880, "见。")]), voice: .melody)
        XCTAssertEqual(chinese.lyricPhrases.map(\.text), ["一起唱，", "再见。"])
        let apostrophe = ScorePerformanceTimeline(score: makeScore(melody: [(0, "don"), (960, "'t"), (1920, "stop.")]), voice: .melody)
        XCTAssertEqual(apostrophe.lyricPhrases.map(\.text), ["don't stop."])
        let multipleLines = ScorePerformanceTimeline(score: makeScore(melody: [(0, "Line one.\nLine two!"), (960, "Next")]), voice: .melody)
        XCTAssertEqual(multipleLines.lyricPhrases.map(\.text), ["Line one.\nLine two!", "Next"])
        XCTAssertEqual(multipleLines.lyricPhrases[0].startTick, 0)
        XCTAssertEqual(multipleLines.lyricPhrases[0].endTick, 960, "One event has no independently timed second sentence")
        let leadingLine = ScorePerformanceTimeline(score: makeScore(melody: [(0, "Hello"), (960, "\nworld")]), voice: .melody)
        XCTAssertEqual(leadingLine.lyricPhrases.map(\.text), ["Hello", "world"])
    }

    func testValidChordMarkersAndStrumArrowsAreRemovedButBracketedLyricsSurvive() {
        let timeline = ScorePerformanceTimeline(score: makeScore(melody: [
            (0, "↓ [Am] 你 ↑"), (960, "[歌词]好，"), (1920, "[not a chord]"), (2880, "[Am I?]")
        ]), voice: .melody)
        XCTAssertEqual(timeline.chordCues, [ScoreChordCue(startTick: 0, symbol: "Am")])
        XCTAssertEqual(timeline.lyricPhrases.map(\.text), ["你[歌词]好，", "[not a chord] [Am I?]"])
        XCTAssertFalse(timeline.lyricPhrases.contains { $0.text.contains("↑") || $0.text.contains("↓") || $0.text.contains("[Am]") })
        let literal = ScorePerformanceTimeline(score: makeScore(melody: [(0, "[Coda] [] [unfinished")]), voice: .melody)
        XCTAssertEqual(literal.lyricPhrases.first?.text, "[Coda] [] [unfinished")
        XCTAssertTrue(literal.chordCues.isEmpty)
        let twoMarkers = ScorePerformanceTimeline(score: makeScore(melody: [(0, "[C][G]你好")]), voice: .melody)
        XCTAssertEqual(twoMarkers.chordCues.first?.symbol, "C", "Only the event onset is timed; do not guess a mid-event G cue")
        XCTAssertEqual(twoMarkers.lyricPhrases.first?.text, "你好")
        let ordinary = ScorePerformanceTimeline(score: makeScore(melody: [(0, "[Am]\nHello"), (960, "↑\n[G]\nworld.")]), voice: .melody)
        XCTAssertEqual(ordinary.lyricPhrases.map(\.text), ["Hello world."], "Pure marker rows must not create artificial lyric boundaries")
    }

    func testChordCuesUseBothVoicesAndSelectedVoiceWinsAtTheSameTick() {
        let score = makeScore(melody: [(0, "[Am]唱。"), (2880, "继续。"), (3840, "[G]终。")],
                              bass: [(0, "[C]低音。"), (1920, "[F]"), (2880, "[Dm]"), (3840, "[D]低音结束。")])
        XCTAssertTrue(ScoreValidator.validate(score).isEmpty)
        let melody = ScorePerformanceTimeline(score: score, voice: .melody)
        XCTAssertEqual(melody.chordCues.map(\.symbol), ["Am", "F", "Dm", "G"])
        XCTAssertEqual(melody.chordCues.map(\.startTick), [0, 1920, 2880, 3840])
        XCTAssertEqual(melody.lyricPhrases.map(\.text), ["唱。", "继续。", "终。"])
        let bass = ScorePerformanceTimeline(score: score, voice: .bass)
        XCTAssertEqual(bass.chordCues.map(\.symbol), ["C", "F", "Dm", "D"])
        XCTAssertEqual(bass.lyricPhrases.map(\.text), ["低音。", "低音结束。"])
        XCTAssertFalse(bass.lyricPhrases.contains { $0.text.contains("唱") })
    }

    func testRepeatedChordsCompressAndHoldAcrossMeasuresUntilTheNextMarker() {
        let score = makeScore(melody: [(480, "[Bb]"), (3840, "[B♭]"), (7680, "[F]"), (11520, "[Bb]")])
        let timeline = ScorePerformanceTimeline(score: score, voice: .melody)
        XCTAssertEqual(timeline.chordCues, [ScoreChordCue(startTick: 480, symbol: "Bb"), ScoreChordCue(startTick: 7680, symbol: "F"), ScoreChordCue(startTick: 11520, symbol: "Bb")])
        XCTAssertNil(timeline.context(at: 479).currentChord)
        XCTAssertEqual(timeline.context(at: 479).nextChord?.symbol, "Bb")
        XCTAssertEqual(timeline.context(at: 480).currentChord?.symbol, "Bb")
        XCTAssertEqual(timeline.context(at: 7679).currentChord?.startTick, 480)
        let change = timeline.context(at: 7680)
        XCTAssertEqual(change.previousChord?.symbol, "Bb")
        XCTAssertEqual(change.currentChord?.symbol, "F")
        XCTAssertEqual(change.nextChord?.startTick, 11520)
        XCTAssertEqual(timeline.context(at: Int.max).currentChord?.symbol, "Bb")
        XCTAssertTrue(timeline.lyricPhrases.isEmpty, "Chord-only markers must not produce empty lyric phrases")
        XCTAssertEqual(timeline.context(at: -960).nextChord?.startTick, 480)
    }

    func testNoLyricsAndUnmarkedChordNamesNeverCreateInferredHarmony() {
        let empty = ScorePerformanceTimeline(score: GuitarScore(), voice: .melody)
        XCTAssertEqual(empty.context(at: 0), ScorePerformanceContext())
        let bare = ScorePerformanceTimeline(score: makeScore(melody: [(0, "Am"), (960, "Love")]), voice: .melody)
        XCTAssertTrue(bare.chordCues.isEmpty)
        XCTAssertEqual(bare.lyricPhrases.first?.text, "Am Love")
        let strumming = ScorePerformanceTimeline(score: makeScore(melody: [(0, "↓ ↑ ↓↑"), (960, "[Am] ↓")]), voice: .melody)
        XCTAssertTrue(strumming.lyricPhrases.isEmpty)
        XCTAssertEqual(strumming.chordCues.first?.startTick, 960)
        var noWords = GuitarScore()
        noWords.measures[0].voices[0].events = [ScoreEvent(startTick: 0, notes: [GuitarNote(string: 1, fret: 0), GuitarNote(string: 2, fret: 1), GuitarNote(string: 3, fret: 0)])]
        XCTAssertTrue(ScorePerformanceTimeline(score: noWords, voice: .melody).chordCues.isEmpty)
        let invalidMeter = ScorePerformanceTimeline(score: GuitarScore(timeSignature: TimeSignature(0, 0)), voice: .melody)
        XCTAssertEqual(invalidMeter.context(at: Int.min), ScorePerformanceContext())
    }

    func testDerivedIDsAreStableAcrossUnrelatedDocumentIdentityChanges() {
        let first = ScorePerformanceTimeline(score: makeScore(melody: [(0, "[C]一。"), (3840, "[G]二。")]), voice: .melody)
        let rebuilt = ScorePerformanceTimeline(score: makeScore(melody: [(0, "[C]一。"), (3840, "[G]二。")]), voice: .melody)
        XCTAssertEqual(first.lyricPhrases, rebuilt.lyricPhrases)
        XCTAssertEqual(first.chordCues, rebuilt.chordCues)
        XCTAssertEqual(Set(first.lyricPhrases.map(\.id)).count, first.lyricPhrases.count)
        XCTAssertEqual(Set(first.chordCues.map(\.id)).count, first.chordCues.count)
    }

    private func makeScore(melody: [(Int, String)], bass: [(Int, String)] = [], signature: TimeSignature = TimeSignature()) -> GuitarScore {
        let capacity = signature.ticks
        let lastTick = (melody + bass).map { $0.0 }.max() ?? 0
        let measures = (0...(lastTick / capacity)).map { measure -> ScoreMeasure in
            let tracks = ScoreVoice.allCases.map { voice -> VoiceTrack in
                let entries = voice == .melody ? melody : bass
                let events = entries.filter { $0.0 / capacity == measure }.map { tick, text in
                    ScoreEvent(startTick: tick % capacity, notes: [GuitarNote(string: voice == .melody ? 1 : 6, fret: 0)], lyric: text)
                }
                return VoiceTrack(voice: voice, events: events)
            }
            return ScoreMeasure(voices: tracks)
        }
        return GuitarScore(timeSignature: signature, measures: measures)
    }
}
