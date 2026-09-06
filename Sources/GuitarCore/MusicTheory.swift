import Foundation

public enum PitchClass: Int, CaseIterable, Codable, Identifiable, Sendable {
    case c = 0, cSharp, d, eFlat, e, f, fSharp, g, aFlat, a, bFlat, b
    public var id: Int { rawValue }
    public var displayName: String { ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"][rawValue] }
    var letter: Int { [0,0,1,2,2,3,3,4,5,5,6,6][rawValue] }
    public init(midi: Int) { self = PitchClass(rawValue: (midi % 12 + 12) % 12)! }
}

public enum ScaleKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case major, naturalMinor, majorPentatonic, minorPentatonic, majorBlues, minorBlues
    public var id: String { rawValue }
    public var title: String {
        switch self { case .major: return "大调"; case .naturalMinor: return "自然小调"; case .majorPentatonic: return "大调五声音阶"; case .minorPentatonic: return "小调五声音阶"; case .majorBlues: return "大调布鲁斯"; case .minorBlues: return "小调布鲁斯" }
    }
    public var intervals: [Int] {
        switch self { case .major: return [0,2,4,5,7,9,11]; case .naturalMinor: return [0,2,3,5,7,8,10]; case .majorPentatonic: return [0,2,4,7,9]; case .minorPentatonic: return [0,3,5,7,10]; case .majorBlues: return [0,2,3,4,7,9]; case .minorBlues: return [0,3,5,6,7,10] }
    }
    public var degrees: [String] {
        switch self { case .major: return ["1","2","3","4","5","6","7"]; case .naturalMinor: return ["1","2","♭3","4","5","♭6","♭7"]; case .majorPentatonic: return ["1","2","3","5","6"]; case .minorPentatonic: return ["1","♭3","4","5","♭7"]; case .majorBlues: return ["1","2","♭3","3","5","6"]; case .minorBlues: return ["1","♭3","4","♭5","5","♭7"] }
    }
    var letterSteps: [Int] {
        switch self { case .major, .naturalMinor: return [0,1,2,3,4,5,6]; case .majorPentatonic: return [0,1,2,4,5]; case .minorPentatonic: return [0,2,3,4,6]; case .majorBlues: return [0,1,2,2,4,5]; case .minorBlues: return [0,2,3,4,4,6] }
    }
    public var isMinor: Bool { [.naturalMinor, .minorPentatonic, .minorBlues].contains(self) }
    public var blueInterval: Int? { self == .majorBlues ? 3 : self == .minorBlues ? 6 : nil }
}

public enum ScalePattern: String, CaseIterable, Codable, Identifiable, Sendable {
    case c = "C", a = "A", g = "G", e = "E", d = "D"
    public var id: String { rawValue }
    public var title: String { "\(rawValue) 形" }
    /// Reference positions use C major / A minor, strings 1 → 6.
    /// Shape names always refer to the relative-major CAGED position.
    public var cMajorFrets: [[Int]] {
        switch self {
        case .c: return [[0,1,3],[0,1,3],[0,2],[0,2,3],[0,2,3],[0,1,3]]
        case .a: return [[3,5],[3,5],[2,4,5],[2,3,5],[2,3,5],[3,5]]
        case .g: return [[5,7,8],[5,6,8],[5,7],[5,7],[5,7,8],[5,7,8]]
        case .e: return [[7,8,10],[8,10],[7,9,10],[7,9,10],[7,8,10],[7,8,10]]
        case .d: return [[10,12,13],[10,12,13],[9,10,12],[9,10,12],[10,12],[10,12,13]]
        }
    }
    public var cMajorPentatonicFrets: [[Int]] {
        switch self {
        case .c: return [[0,3],[1,3],[0,2],[0,2],[0,3],[0,3]]
        case .a: return [[3,5],[3,5],[2,5],[2,5],[3,5],[3,5]]
        case .g: return [[5,8],[5,8],[5,7],[5,7],[5,7],[5,8]]
        case .e: return [[8,10],[8,10],[7,9],[7,10],[7,10],[8,10]]
        case .d: return [[10,12],[10,13],[9,12],[10,12],[10,12],[10,12]]
        }
    }
    /// Pentatonic boxes with every adjacent E-flat passing tone, including edge extensions.
    /// A reference fret of -1 becomes playable after transposition; it is omitted at the nut.
    public var cMajorBluesFrets: [[Int]] {
        switch self {
        case .c: return [[-1,0,3],[1,3,4],[0,2],[0,1,2],[0,3],[-1,0,3]]
        case .a: return [[3,5],[3,4,5],[2,5],[1,2,5],[3,5,6],[3,5]]
        case .g: return [[5,8],[4,5,8],[5,7,8],[5,7],[5,6,7],[5,8]]
        case .e: return [[8,10,11],[8,10],[7,8,9],[7,10],[6,7,10],[8,10,11]]
        case .d: return [[10,11,12],[10,13],[8,9,12],[10,12,13],[10,12],[10,11,12]]
        }
    }
    public func referenceFrets(for kind: ScaleKind) -> [[Int]] {
        switch kind {
        case .major, .naturalMinor: return cMajorFrets
        case .majorPentatonic, .minorPentatonic: return cMajorPentatonicFrets
        case .majorBlues, .minorBlues: return cMajorBluesFrets
        }
    }
    public var explanation: String { "\(rawValue) 形按关系大调的 CAGED 位置命名，小调沿用关系大调的位置。七声、五声与布鲁斯使用各自的固定指型；布鲁斯含盒形边缘相邻的蓝调扩展音。" }
}

public struct FretPosition: Identifiable, Hashable, Sendable {
    public var string: Int
    public var fret: Int
    public var midi: Int
    public var pitchClass: Int
    public var isRoot: Bool
    public var isBlue: Bool
    public var degree: String
    public var name: String
    public var id: String { "\(string)-\(fret)" }
    public init(string: Int, fret: Int, midi: Int, pitchClass: Int, isRoot: Bool, isBlue: Bool, degree: String, name: String) {
        self.string = string; self.fret = fret; self.midi = midi; self.pitchClass = pitchClass; self.isRoot = isRoot; self.isBlue = isBlue; self.degree = degree; self.name = name
    }
}

public enum MusicTheory {
    public static let standardTuning = [64,59,55,50,45,40]
    public static func frequency(midi: Double, a4: Double = 440) -> Double { a4 * pow(2, (midi - 69) / 12) }
    public static func midi(frequency: Double, a4: Double = 440) -> Double { 69 + 12 * log2(max(Double.leastNonzeroMagnitude, frequency) / a4) }
    public static func noteName(midi: Int) -> String { "\(PitchClass(midi: midi).displayName)\(midi / 12 - 1)" }
    public static func noteName(midi: Int, spelledName: String) -> String {
        guard let letter = spelledName.first, let natural = ["C":0,"D":2,"E":4,"F":5,"G":7,"A":9,"B":11][String(letter)] else { return noteName(midi: midi) }
        let alteration = spelledName.dropFirst().reduce(0) { $0 + ($1 == "♯" ? 1 : $1 == "♭" ? -1 : 0) }
        // Written octave follows the letter: MIDI 60 is B-sharp 3, MIDI 59 is C-flat 4.
        return "\(spelledName)\((midi - natural - alteration) / 12 - 1)"
    }
    public static func scalePitchClasses(root: PitchClass, kind: ScaleKind) -> [Int] { kind.intervals.map { (root.rawValue + $0) % 12 } }
    static func spelling(pitchClass: Int, letter: Int) -> String {
        let natural = [0,2,4,5,7,9,11][letter % 7]
        var difference = (pitchClass - natural + 12) % 12
        if difference > 6 { difference -= 12 }
        let accidental = difference > 0 ? String(repeating: "♯", count: difference) : String(repeating: "♭", count: -difference)
        return ["C","D","E","F","G","A","B"][letter % 7] + accidental
    }
    public static func spelledNotes(root: PitchClass, kind: ScaleKind) -> [String] {
        zip(kind.intervals, kind.letterSteps).map { spelling(pitchClass: (root.rawValue + $0) % 12, letter: (root.letter + $1) % 7) }
    }
    public static func relativeRoot(root: PitchClass, kind: ScaleKind) -> PitchClass { PitchClass(midi: root.rawValue + (kind.isMinor ? 3 : 9)) }
    public static func relativeKeyDescription(root: PitchClass, kind: ScaleKind) -> String {
        let offset = kind.isMinor ? 3 : 9
        let letter = (root.letter + (kind.isMinor ? 2 : 5)) % 7
        return spelling(pitchClass: (root.rawValue + offset) % 12, letter: letter) + (kind.isMinor ? " 大调" : " 小调")
    }
    public static func fretboard(root: PitchClass, kind: ScaleKind, pattern: ScalePattern? = nil, maxFret: Int = 24) -> [FretPosition] {
        let classes = scalePitchClasses(root: root, kind: kind), names = spelledNotes(root: root, kind: kind)
        let relativeMajor = (root.rawValue + (kind.isMinor ? 3 : 0)) % 12
        var result: [FretPosition] = []
        guard maxFret >= 0 else { return result }
        for string in 1...6 {
            let frets: [Int]
            if let pattern {
                let shape = pattern.referenceFrets(for: kind)
                let reference = shape[string - 1]
                let shift = relativeMajor
                // Move the whole reference shape down an octave if it otherwise leaves the instrument.
                let octaveShift = (shape.flatMap { $0 }.max()! + shift > maxFret && shape.flatMap { $0 }.min()! + shift >= 12) ? -12 : 0
                frets = reference.map { $0 + shift + octaveShift }
            } else { frets = Array(0...maxFret) }
            for fret in frets where (0...maxFret).contains(fret) {
                let midi = standardTuning[string - 1] + fret, pc = midi % 12
                guard let index = classes.firstIndex(of: pc) else { continue }
                let interval = (pc - root.rawValue + 12) % 12
                result.append(FretPosition(string: string, fret: fret, midi: midi, pitchClass: pc, isRoot: interval == 0,
                    isBlue: kind.blueInterval == interval, degree: kind.degrees[index], name: names[index]))
            }
        }
        return result
    }

    public static func scaleExercise(root: PitchClass, kind: ScaleKind, pattern: ScalePattern? = nil, descending: Bool = false) -> GuitarScore {
        let positions = fretboard(root: root, kind: kind, pattern: pattern, maxFret: 15).sorted { $0.midi == $1.midi ? $0.fret < $1.fret : $0.midi < $1.midi }
        var seen = Set<Int>()
        var path = positions.filter { seen.insert($0.midi).inserted }
        if descending { path.reverse() }
        return exercise(title: "\(root.displayName) \(kind.title)\(pattern.map { " · " + $0.title } ?? "")", positions: path)
    }
    public static func exercise(title: String, positions: [FretPosition], rhythm: Rhythm = Rhythm(.eighth)) -> GuitarScore {
        var measures: [ScoreMeasure] = []; var current = ScoreMeasure(); var tick = 0
        for position in positions {
            if tick + rhythm.ticks > 3840 { measures.append(current); current = ScoreMeasure(); tick = 0 }
            current.voices[0].events.append(ScoreEvent(startTick: tick, rhythm: rhythm, notes: [GuitarNote(string: position.string, fret: position.fret)]))
            tick += rhythm.ticks
        }
        if !current.voices[0].events.isEmpty || measures.isEmpty { measures.append(current) }
        return GuitarScore(title: title, measures: measures)
    }
}

/// Shared by the learning UI and tests, so generated exercises use one implementation.
public enum ExerciseBuilder {
    public static func score(title: String, positions: [FretPosition], returnDown: Bool = false) -> GuitarScore {
        let sorted = positions.sorted { $0.midi == $1.midi ? $0.string > $1.string : $0.midi < $1.midi }
        var seen = Set<Int>()
        let ascending = sorted.filter { seen.insert($0.midi).inserted }
        let sequence = returnDown ? ascending + ascending.dropLast().reversed() : ascending
        return MusicTheory.exercise(title: title, positions: sequence)
    }
}

public struct ChordPosition: Identifiable, Equatable, Sendable {
    public var string: Int
    public var fret: Int?
    /// 0 denotes open string. 1–4 denote index through little finger.
    public var finger: Int?
    public var id: Int { string }
    public var isMuted: Bool { fret == nil }
    public var isOpen: Bool { fret == 0 }
}

public struct CAGEDChord: Sendable {
    public var name: String
    public var shape: ScalePattern
    public var minor: Bool
    public var positions: [ChordPosition]
    public var arpeggio: [FretPosition]
    public var explanation: String
    public static func make(root: PitchClass, shape: ScalePattern, minor: Bool = false) -> CAGEDChord {
        let baseRoot: Int, base: [Int?], fingers: [Int?]
        switch (shape, minor) {
        case (.c, false): baseRoot = 0; base = [0,1,0,2,3,nil]; fingers = [0,1,0,2,3,nil]
        case (.a, false): baseRoot = 9; base = [0,2,2,2,0,nil]; fingers = [0,3,3,3,0,nil]
        case (.g, false): baseRoot = 7; base = [3,0,0,0,2,3]; fingers = [4,0,0,0,2,3]
        case (.e, false): baseRoot = 4; base = [0,0,1,2,2,0]; fingers = [0,0,1,3,2,0]
        case (.d, false): baseRoot = 2; base = [2,3,2,0,nil,nil]; fingers = [2,3,1,0,nil,nil]
        case (.c, true): baseRoot = 0; base = [nil,1,0,1,3,nil]; fingers = [nil,2,0,1,3,nil]
        case (.a, true): baseRoot = 9; base = [0,1,2,2,0,nil]; fingers = [0,1,3,2,0,nil]
        case (.g, true): baseRoot = 7; base = [3,3,3,0,nil,nil]; fingers = [1,1,1,0,nil,nil]
        case (.e, true): baseRoot = 4; base = [0,0,0,2,2,0]; fingers = [0,0,0,3,2,0]
        case (.d, true): baseRoot = 2; base = [1,3,2,0,nil,nil]; fingers = [1,3,2,0,nil,nil]
        }
        let shift = (root.rawValue - baseRoot + 12) % 12
        var positions: [ChordPosition] = []
        for string in 1...6 {
            let fret = base[string - 1].map { $0 + shift }
            let original = fingers[string - 1]
            let finger = shift == 0 ? original : original.map { $0 == 0 ? 1 : min(4, $0 + 1) }
            positions.append(ChordPosition(string: string, fret: fret, finger: finger))
        }
        if shape == .g && !minor && shift > 0 {
            // The complete movable G grip spans both outer strings with a barre in between.
            // Use its common four-string root-position reduction instead of impossible finger labels.
            positions[0].fret = nil; positions[0].finger = nil
            positions[4].fret = nil; positions[4].finger = nil
        }
        // The G minor variant deliberately omits the low root and uses a compact top-string barre.
        let kind: ScaleKind = minor ? .naturalMinor : .major
        let thirds = [0, minor ? 3 : 4, 7]
        let gripFrets = positions.compactMap(\.fret)
        let region = (gripFrets.min() ?? 0)...(gripFrets.max() ?? 3)
        let arpeggio = MusicTheory.fretboard(root: root, kind: kind).filter { candidate in
            thirds.contains((candidate.pitchClass - root.rawValue + 12) % 12) &&
            region.contains(candidate.fret)
        }.sorted { $0.midi < $1.midi }
        let detail = minor && (shape == .c || shape == .g) ? "复杂小调形状使用可演奏的四弦简化按法；消音弦不发声。" : shape == .g && shift > 0 ? "移动 G 形使用保留低音根音的四弦简化按法；消音弦不发声。" : "形状名称说明手型，实际和弦名称由所选根音决定。"
        return CAGEDChord(name: root.displayName + (minor ? "m" : ""), shape: shape, minor: minor, positions: positions, arpeggio: arpeggio, explanation: detail)
    }
}

public enum TriadQuality: String, Sendable { case major, minor, diminished
    public var title: String { self == .major ? "大三和弦" : self == .minor ? "小三和弦" : "减三和弦" }
}
public struct DiatonicTriad: Identifiable, Sendable {
    public var degree: Int
    public var name: String
    public var quality: TriadQuality
    public var roman: String
    public var pitchClasses: [Int]
    public var notes: [String]
    public var id: Int { degree }
    public var title: String { "\(roman) · \(name) · \(quality.title)" }
    public static func all(in root: PitchClass) -> [DiatonicTriad] {
        let classes = MusicTheory.scalePitchClasses(root: root, kind: .major), spelled = MusicTheory.spelledNotes(root: root, kind: .major)
        let qualities: [TriadQuality] = [.major,.minor,.minor,.major,.major,.minor,.diminished]
        let romans = ["I","ii","iii","IV","V","vi","vii°"]
        return (0..<7).map { index in
            let indices = [index, (index + 2) % 7, (index + 4) % 7]
            let suffix = qualities[index] == .major ? "" : qualities[index] == .minor ? "m" : "dim"
            return DiatonicTriad(degree: index + 1, name: spelled[index] + suffix, quality: qualities[index], roman: romans[index], pitchClasses: indices.map { classes[$0] }, notes: indices.map { spelled[$0] })
        }
    }
}
