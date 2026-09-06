import Foundation

/// Original beginner tablature arrangements in standard tuning. Historical melodies and
/// lyrics used here are public domain; no third-party arrangement or recording is included.
public enum StarterScores {
    public static var all: [GuitarScore] {
        [chromatic, cMajorScale, arpeggio, twinkleTwinkle, odeToJoy, frereJacques]
    }

    private static var chromatic: GuitarScore {
        let outbound = (1...6).reversed().map { string in
            measure((1...4).map { tone((string, $0)) })
        }
        let returning = (1...6).map { string in
            measure((1...4).reversed().map { tone((string, $0)) })
        }
        return GuitarScore(title: "基本功 · 1-2-3-4 半音爬格子", bpm: 60, measures: outbound + returning)
    }

    private static var cMajorScale: GuitarScore {
        GuitarScore(title: "基本功 · C 大调音阶上下行", bpm: 60, measures: [
            measure([tone(c), tone(d), tone(e), tone(f)]),
            measure([tone(g), tone(a), tone(b), tone(highC)]),
            measure([tone(b), tone(a), tone(g), tone(f)]),
            measure([tone(e), tone(d), tone(c, .half)])
        ])
    }

    private static var arpeggio: GuitarScore {
        // C, Am, Fmaj7, G. Right hand: p-i-m-a-m-i-m-i, eight even eighth notes.
        // Fmaj7 uses the upper four strings, so a first-fret barre is not required.
        let shapes: [[Position]] = [
            [(5,3), (3,0), (2,1), (1,0), (2,1), (3,0), (2,1), (3,0)],
            [(5,0), (3,2), (2,1), (1,0), (2,1), (3,2), (2,1), (3,2)],
            [(4,3), (3,2), (2,1), (1,0), (2,1), (3,2), (2,1), (3,2)],
            [(6,3), (3,0), (2,0), (1,3), (2,0), (3,0), (2,0), (3,0)]
        ]
        return GuitarScore(title: "基本功 · C–Am–Fmaj7–G 分解和弦", bpm: 60,
            measures: (shapes + shapes).map { measure($0.map { tone($0, .eighth) }) })
    }

    private static var twinkleTwinkle: GuitarScore {
        // Traditional French tune; Jane Taylor's "The Star" (1806), first stanza.
        // One lyric segment belongs to one rhythmic event, including the half-note endings.
        GuitarScore(title: "小星星 · Twinkle Twinkle Little Star（歌词）", bpm: 72, measures: [
            measure([tone(c, lyric: "Twin-"), tone(c, lyric: "kle,"), tone(g, lyric: "twin-"), tone(g, lyric: "kle,")]),
            measure([tone(a, lyric: "lit-"), tone(a, lyric: "tle"), tone(g, .half, lyric: "star,")]),
            measure([tone(f, lyric: "How"), tone(f, lyric: "I"), tone(e, lyric: "won-"), tone(e, lyric: "der")]),
            measure([tone(d, lyric: "what"), tone(d, lyric: "you"), tone(c, .half, lyric: "are!")]),
            measure([tone(g, lyric: "Up"), tone(g, lyric: "a-"), tone(f, lyric: "bove"), tone(f, lyric: "the")]),
            measure([tone(e, lyric: "world"), tone(e, lyric: "so"), tone(d, .half, lyric: "high,")]),
            measure([tone(g, lyric: "Like"), tone(g, lyric: "a"), tone(f, lyric: "dia-"), tone(f, lyric: "mond")]),
            measure([tone(e, lyric: "in"), tone(e, lyric: "the"), tone(d, .half, lyric: "sky.")]),
            measure([tone(c, lyric: "Twin-"), tone(c, lyric: "kle,"), tone(g, lyric: "twin-"), tone(g, lyric: "kle,")]),
            measure([tone(a, lyric: "lit-"), tone(a, lyric: "tle"), tone(g, .half, lyric: "star,")]),
            measure([tone(f, lyric: "How"), tone(f, lyric: "I"), tone(e, lyric: "won-"), tone(e, lyric: "der")]),
            measure([tone(d, lyric: "what"), tone(d, lyric: "you"), tone(c, .half, lyric: "are!")])
        ])
    }

    private static var odeToJoy: GuitarScore {
        // Beethoven, Symphony No. 9 (1824), opening eight bars of the familiar theme in C.
        GuitarScore(title: "欢乐颂 · Ode to Joy（主题）", bpm: 72, measures: [
            measure([tone(e), tone(e), tone(f), tone(g)]),
            measure([tone(g), tone(f), tone(e), tone(d)]),
            measure([tone(c), tone(c), tone(d), tone(e)]),
            measure([tone(e, dotted: true), tone(d, .eighth), tone(d, .half)]),
            measure([tone(e), tone(e), tone(f), tone(g)]),
            measure([tone(g), tone(f), tone(e), tone(d)]),
            measure([tone(c), tone(c), tone(d), tone(e)]),
            measure([tone(d, dotted: true), tone(c, .eighth), tone(c, .half)])
        ])
    }

    private static var frereJacques: GuitarScore {
        // Traditional French round, single melody. The final G is below the tonic C.
        GuitarScore(title: "两只老虎旋律 · Frère Jacques（法语歌词）", bpm: 72, measures: [
            measure([tone(c, lyric: "Frè-"), tone(d, lyric: "re"), tone(e, lyric: "Jac-"), tone(c, lyric: "ques,")]),
            measure([tone(c, lyric: "Frè-"), tone(d, lyric: "re"), tone(e, lyric: "Jac-"), tone(c, lyric: "ques,")]),
            measure([tone(e, lyric: "Dor-"), tone(f, lyric: "mez-"), tone(g, .half, lyric: "vous ?")]),
            measure([tone(e, lyric: "Dor-"), tone(f, lyric: "mez-"), tone(g, .half, lyric: "vous ?")]),
            measure([tone(g, .eighth, lyric: "Son-"), tone(a, .eighth, lyric: "nez"), tone(g, .eighth, lyric: "les"), tone(f, .eighth, lyric: "ma-"), tone(e, lyric: "ti-"), tone(c, lyric: "nes,")]),
            measure([tone(g, .eighth, lyric: "Son-"), tone(a, .eighth, lyric: "nez"), tone(g, .eighth, lyric: "les"), tone(f, .eighth, lyric: "ma-"), tone(e, lyric: "ti-"), tone(c, lyric: "nes,")]),
            measure([tone(c, lyric: "Ding,"), tone(lowG, lyric: "ding,"), tone(c, .half, lyric: "dong.")]),
            measure([tone(c, lyric: "Ding,"), tone(lowG, lyric: "ding,"), tone(c, .half, lyric: "dong.")])
        ])
    }

    // These are sounding pitches (C = C3/MIDI 48), all within open position.
    private typealias Position = (string: Int, fret: Int)
    private static let lowG: Position = (6,3)
    private static let c: Position = (5,3)
    private static let d: Position = (4,0)
    private static let e: Position = (4,2)
    private static let f: Position = (4,3)
    private static let g: Position = (3,0)
    private static let a: Position = (3,2)
    private static let b: Position = (2,0)
    private static let highC: Position = (2,1)
    private typealias Tone = (position: Position, rhythm: Rhythm, lyric: String?)

    private static func tone(_ position: Position, _ value: NoteValue = .quarter,
                             dotted: Bool = false, lyric: String? = nil) -> Tone {
        (position, Rhythm(value, dotted: dotted), lyric)
    }

    private static func measure(_ tones: [Tone]) -> ScoreMeasure {
        var tick = 0
        let events = tones.map { tone in
            var event = ScoreEvent(startTick: tick, rhythm: tone.rhythm,
                notes: [GuitarNote(string: tone.position.string, fret: tone.position.fret)])
            event.lyric = tone.lyric
            tick += tone.rhythm.ticks
            return event
        }
        return ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: events), VoiceTrack(voice: .bass)])
    }
}
