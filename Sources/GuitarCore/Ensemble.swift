import Foundation

public enum JamStyle: String, CaseIterable, Identifiable, Sendable {
    case folk, pop, minorBallad, blues
    public var id: String { rawValue }
    public var title: String {
        switch self { case .folk: return "民谣分解"; case .pop: return "流行切分"; case .minorBallad: return "小调慢板"; case .blues: return "十二小节布鲁斯" }
    }
    public var defaultBPM: Double {
        switch self { case .folk: return 80; case .pop: return 100; case .minorBallad: return 68; case .blues: return 92 }
    }
    public var isMinor: Bool { self == .minorBallad }
    public var progression: [Int] {
        switch self {
        case .folk, .pop: return [0, 4, 5, 3]
        case .minorBallad: return [0, 5, 2, 6]
        case .blues: return [0,0,0,0,3,3,0,0,4,3,0,4]
        }
    }
    public var description: String {
        switch self {
        case .folk: return "I–V–vi–IV · 八分分解与根音低音"
        case .pop: return "I–V–vi–IV · 切分和弦与二分低音"
        case .minorBallad: return "i–VI–III–VII · 留白分解与持续低音"
        case .blues: return "I7–IV7–V7 · 十二小节、直八分律动"
        }
    }
}

public enum JamRecommendation: String, CaseIterable, Identifiable, Sendable {
    case chordTones, pentatonic, keyScale
    public var id: String { rawValue }
    public var title: String {
        switch self { case .chordTones: return "当前和弦音"; case .pentatonic: return "五声音阶"; case .keyScale: return "调内音阶" }
    }
}

public struct JamChord: Sendable, Identifiable {
    public var measure: Int
    public var root: PitchClass
    public var kind: ChordKind
    public var name: String
    public var roman: String
    public var noteNames: [String]
    public var id: Int { measure }
    public var pitchClasses: [Int] { kind.intervals.map { (root.rawValue + $0) % 12 } }
}

public struct JamArrangement: Sendable {
    public let root: PitchClass
    public let style: JamStyle
    public let chords: [JamChord]
    public let score: GuitarScore

    /// The audio renderer wraps its own tick at a loop. Before count-in finishes the first chord remains selected.
    public func chord(atTick tick: Int) -> JamChord {
        chords[min(chords.count - 1, max(0, tick) / score.timeSignature.ticks)]
    }

    public func recommendations(atTick tick: Int, mode: JamRecommendation, maxFret: Int = 15) -> [FretPosition] {
        let chord = chord(atTick: tick)
        if mode == .chordTones {
            return (1...6).flatMap { string in
                (0...max(0, min(24, maxFret))).compactMap { fret -> FretPosition? in
                    let midi = MusicTheory.standardTuning[string - 1] + fret
                    guard let index = chord.pitchClasses.firstIndex(of: midi % 12) else { return nil }
                    return FretPosition(string: string, fret: fret, midi: midi, pitchClass: midi % 12,
                        isRoot: index == 0, isBlue: false, degree: chord.kind.degrees[index], name: chord.noteNames[index])
                }
            }
        }
        let kind: ScaleKind = mode == .pentatonic
            ? (style.isMinor || style == .blues ? .minorPentatonic : .majorPentatonic)
            : (style.isMinor ? .naturalMinor : style == .blues ? .minorBlues : .major)
        return MusicTheory.fretboard(root: root, kind: kind, maxFret: max(0, min(24, maxFret)))
    }
}

/// Original practice arrangements generated entirely locally using the shared two-voice score model.
public enum JamBuilder {
    public static func make(root: PitchClass, style: JamStyle, bpm: Double? = nil) -> JamArrangement {
        let scale: ScaleKind = style.isMinor ? .naturalMinor : .major
        let names = MusicTheory.spelledNotes(root: root, kind: scale)
        let classes = MusicTheory.scalePitchClasses(root: root, kind: scale)
        let minorDegrees = style.isMinor ? [0,3,4] : [1,2,5]
        let romans = style.isMinor ? ["i","ii°","III","iv","v","VI","VII"] : ["I","ii","iii","IV","V","vi","vii°"]
        let chords = style.progression.enumerated().map { index, degree in
            let kind: ChordKind = style == .blues ? .dominant7 : minorDegrees.contains(degree) ? .minor : .major
            let chordRoot = PitchClass(midi: classes[degree])
            let tones = kind.intervals.enumerated().map { offset, interval in
                MusicTheory.spelling(pitchClass: (chordRoot.rawValue + interval) % 12, letter: root.letter + degree + offset * 2)
            }
            return JamChord(measure: index, root: chordRoot, kind: kind, name: names[degree] + kind.suffix,
                roman: romans[degree] + (style == .blues ? "7" : ""), noteNames: tones)
        }
        var previous = [Int](repeating: 0, count: 4)
        let measures = chords.map { chord -> ScoreMeasure in
            let voicing = accompanimentVoicing(chord: chord, style: style, previous: previous)
            let upper = voicing.upper
            previous = upper.map(\.fret)
            let bassRoot = fresh(voicing.bass[0]!)
            let bassFifth = fresh(voicing.bass[7] ?? voicing.bass[0]!)
            var bass: [ScoreEvent] = []
            var harmony: [ScoreEvent] = []
            switch style {
            case .folk:
                bass = [ScoreEvent(startTick: 0, rhythm: Rhythm(.half), notes: [bassRoot]), ScoreEvent(startTick: 1920, rhythm: Rhythm(.half), notes: [bassFifth])]
                let pattern = [3,2,1,0,2,1,0,1]
                harmony = pattern.enumerated().map { i, index in ScoreEvent(startTick: i * 480, rhythm: Rhythm(.eighth), notes: [fresh(upper[index])]) }
            case .pop:
                bass = [ScoreEvent(startTick: 0, rhythm: Rhythm(.half), notes: [bassRoot]), ScoreEvent(startTick: 1920, rhythm: Rhythm(.half), notes: [bassFifth])]
                harmony = [0,720,1440,2400,3120].map { tick in
                    ScoreEvent(startTick: tick, rhythm: Rhythm(.eighth), notes: upper.map { note in
                        var played = fresh(note); played.velocity = tick == 0 ? 0.53 : 0.40; return played
                    })
                }
            case .minorBallad:
                bass = [ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [bassRoot])]
                harmony = [3,1,2,0].enumerated().map { i, index in ScoreEvent(startTick: i * 960, notes: [fresh(upper[index])]) }
            case .blues:
                bass = [0,7,10,7].enumerated().map { i, interval in
                    ScoreEvent(startTick: i * 960, notes: [fresh(voicing.bass[interval]!)])
                }
                harmony = [0,960,1920,2880].map { tick in ScoreEvent(startTick: tick, rhythm: Rhythm(.eighth), notes: upper.map { note in
                    var played = fresh(note); played.velocity = 0.40; played.technique = .palmMute; return played
                }) }
            }
            return ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: harmony), VoiceTrack(voice: .bass, events: bass)])
        }
        let requestedTempo = bpm ?? style.defaultBPM
        let tempo = requestedTempo.isFinite ? max(40, min(180, requestedTempo)) : style.defaultBPM
        return JamArrangement(root: root, style: style, chords: chords,
            score: GuitarScore(title: "合奏 · \(root.displayName) · \(style.title)", bpm: tempo, measures: measures))
    }

    private static func fresh(_ note: GuitarNote) -> GuitarNote {
        var copy = note; copy.id = UUID(); return copy
    }

    private static func accompanimentVoicing(chord: JamChord, style: JamStyle, previous: [Int]) -> (upper: [GuitarNote], bass: [Int: GuitarNote]) {
        let required = Set(chord.pitchClasses)
        let options = (1...4).map { string in (0...12).filter { required.contains((MusicTheory.standardTuning[string - 1] + $0) % 12) } }
        let bassIntervals = style == .blues ? [0,7,10] : style == .minorBallad ? [0] : [0,7]
        var best: [Int] = [], cost = Int.max
        var bestBass: [Int: GuitarNote] = [:]
        for a in options[0] { for b in options[1] { for c in options[2] { for d in options[3] {
            let frets = [a,b,c,d]
            let played = Set(frets.enumerated().map { (MusicTheory.standardTuning[$0.offset] + $0.element) % 12 })
            guard played == required else { continue }
            let stopped = frets.filter { $0 > 0 }
            let span = (stopped.max() ?? 0) - (stopped.min() ?? 0)
            guard span <= 4 else { continue }
            var bass: [Int: GuitarNote] = [:]
            for interval in bassIntervals {
                let pitchClass = (chord.root.rawValue + interval) % 12
                let choices = [6,5].flatMap { string -> [GuitarNote] in
                    (0...12).filter { (MusicTheory.standardTuning[string - 1] + $0) % 12 == pitchClass }.map {
                        GuitarNote(string: string, fret: $0, velocity: 0.6)
                    }
                }.filter { note in
                    var grip = frets.map(Optional.some) + [nil, nil]
                    grip[note.string - 1] = note.fret
                    return ChordLibrary.canFinger(frets: grip, maximumSpan: 4)
                }
                if let note = choices.min(by: { $0.fret == $1.fret ? $0.string > $1.string : $0.fret < $1.fret }) {
                    bass[interval] = note
                }
            }
            guard bass.count == bassIntervals.count else { continue }
            let candidate = span * 6 + frets.reduce(0,+) + bass.values.map(\.fret).reduce(0,+) * 2 + zip(frets,previous).map { abs($0 - $1) }.reduce(0,+)
            if candidate < cost { cost = candidate; best = frets; bestBass = bass }
        } } } }
        precondition(best.count == 4, "Missing playable accompaniment voicing")
        return (best.enumerated().map { GuitarNote(string: $0.offset + 1, fret: $0.element, velocity: 0.47) }, bestBass)
    }
}
