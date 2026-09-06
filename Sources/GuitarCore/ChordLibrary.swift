import Foundation

public enum ChordKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case major, minor, dominant7, major7, minor7, suspended2, suspended4
    case diminished, augmented, diminished7, halfDiminished7, major6, minor6, add9, dominant9

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .major: return "大三和弦"
        case .minor: return "小三和弦"
        case .dominant7: return "属七和弦"
        case .major7: return "大七和弦"
        case .minor7: return "小七和弦"
        case .suspended2: return "挂二和弦"
        case .suspended4: return "挂四和弦"
        case .diminished: return "减三和弦"
        case .augmented: return "增三和弦"
        case .diminished7: return "减七和弦"
        case .halfDiminished7: return "半减七和弦"
        case .major6: return "大六和弦"
        case .minor6: return "小六和弦"
        case .add9: return "加九和弦"
        case .dominant9: return "属九和弦"
        }
    }
    public var suffix: String {
        switch self {
        case .major: return ""
        case .minor: return "m"
        case .dominant7: return "7"
        case .major7: return "maj7"
        case .minor7: return "m7"
        case .suspended2: return "sus2"
        case .suspended4: return "sus4"
        case .diminished: return "dim"
        case .augmented: return "aug"
        case .diminished7: return "dim7"
        case .halfDiminished7: return "m7♭5"
        case .major6: return "6"
        case .minor6: return "m6"
        case .add9: return "add9"
        case .dominant9: return "9"
        }
    }
    public var intervals: [Int] {
        switch self {
        case .major: return [0, 4, 7]
        case .minor: return [0, 3, 7]
        case .dominant7: return [0, 4, 7, 10]
        case .major7: return [0, 4, 7, 11]
        case .minor7: return [0, 3, 7, 10]
        case .suspended2: return [0, 2, 7]
        case .suspended4: return [0, 5, 7]
        case .diminished: return [0, 3, 6]
        case .augmented: return [0, 4, 8]
        case .diminished7: return [0, 3, 6, 9]
        case .halfDiminished7: return [0, 3, 6, 10]
        case .major6: return [0, 4, 7, 9]
        case .minor6: return [0, 3, 7, 9]
        case .add9: return [0, 4, 7, 14]
        case .dominant9: return [0, 4, 7, 10, 14]
        }
    }
    public var degrees: [String] {
        switch self {
        case .major: return ["1", "3", "5"]
        case .minor: return ["1", "♭3", "5"]
        case .dominant7: return ["1", "3", "5", "♭7"]
        case .major7: return ["1", "3", "5", "7"]
        case .minor7: return ["1", "♭3", "5", "♭7"]
        case .suspended2: return ["1", "2", "5"]
        case .suspended4: return ["1", "4", "5"]
        case .diminished: return ["1", "♭3", "♭5"]
        case .augmented: return ["1", "3", "♯5"]
        case .diminished7: return ["1", "♭3", "♭5", "♭♭7"]
        case .halfDiminished7: return ["1", "♭3", "♭5", "♭7"]
        case .major6: return ["1", "3", "5", "6"]
        case .minor6: return ["1", "♭3", "5", "6"]
        case .add9: return ["1", "3", "5", "9"]
        case .dominant9: return ["1", "3", "5", "♭7", "9"]
        }
    }
    private var letterSteps: [Int] {
        switch self {
        case .suspended2: return [0, 1, 4]
        case .suspended4: return [0, 3, 4]
        case .major6, .minor6: return [0, 2, 4, 5]
        case .add9: return [0, 2, 4, 1]
        case .dominant9: return [0, 2, 4, 6, 1]
        default: return intervals.count == 3 ? [0, 2, 4] : [0, 2, 4, 6]
        }
    }
    fileprivate func noteNames(root: PitchClass) -> [String] {
        zip(intervals, letterSteps).map {
            MusicTheory.spelling(pitchClass: (root.rawValue + $0.0) % 12, letter: (root.letter + $0.1) % 7)
        }
    }
}

public struct ChordDefinition: Hashable, Codable, Identifiable, Sendable {
    public var root: PitchClass
    public var kind: ChordKind
    public init(root: PitchClass, kind: ChordKind) { self.root = root; self.kind = kind }
    public var id: String { "\(root.rawValue)-\(kind.rawValue)" }
    public var name: String { root.displayName + kind.suffix }
    public var pitchClasses: [Int] { kind.intervals.map { (root.rawValue + $0) % 12 } }
    public var noteNames: [String] { kind.noteNames(root: root) }
    public var degrees: [String] { kind.degrees }
}

public struct ChordSearchOptions: Hashable, Sendable {
    /// These limits apply to fretted notes; open strings are independently enabled below.
    public var minimumFret: Int
    public var maximumFret: Int
    /// Highest minus lowest fretted note. Open strings do not increase this span.
    public var maximumSpan: Int
    public var minimumStrings: Int
    public var maximumStrings: Int
    public var rootInBass: Bool
    public var allowOpenStrings: Bool
    public var allowBarre: Bool
    public var maximumFingers: Int
    public init(minimumFret: Int = 1, maximumFret: Int = 12, maximumSpan: Int = 3,
                minimumStrings: Int = 3, maximumStrings: Int = 6, rootInBass: Bool = false,
                allowOpenStrings: Bool = true, allowBarre: Bool = true, maximumFingers: Int = 4) {
        self.minimumFret = minimumFret; self.maximumFret = maximumFret; self.maximumSpan = maximumSpan
        self.minimumStrings = minimumStrings; self.maximumStrings = maximumStrings; self.rootInBass = rootInBass
        self.allowOpenStrings = allowOpenStrings; self.allowBarre = allowBarre; self.maximumFingers = maximumFingers
    }
    public var explanation: String {
        "按弦范围 \(minimumFret)–\(maximumFret) 品，按弦最高与最低品差不超过 \(maximumSpan)；\(minimumStrings)–\(maximumStrings) 根弦发声，最多 \(maximumFingers) 指。"
        + (allowOpenStrings ? "允许范围外的空弦。" : "不使用空弦。")
        + (rootInBass ? "实际最低音须为根音。" : "允许转位。")
        + (allowBarre ? "允许连续横按。" : "不使用横按。")
    }
}

public struct ChordBarre: Hashable, Sendable, Identifiable {
    public let finger: Int
    public let fret: Int
    public let fromString: Int
    public let toString: Int
    public var id: String { "\(finger)-\(fret)-\(fromString)-\(toString)" }
}

public struct ChordVoicing: Hashable, Sendable, Identifiable {
    public let chord: ChordDefinition
    /// First string to sixth string. nil means deliberately muted; zero means open.
    public let frets: [Int?]
    public let fingers: [Int?]
    public let barres: [ChordBarre]
    public let fingerCount: Int
    public var id: String { chord.id + ":" + frets.map { $0.map(String.init) ?? "x" }.joined(separator: "-") }
    public var positions: [ChordPosition] {
        (1...6).map { ChordPosition(string: $0, fret: frets[$0 - 1], finger: fingers[$0 - 1]) }
    }
    /// Low string to high string, suitable for a downward strum or string-by-string drill.
    public var notes: [GuitarNote] { (1...6).reversed().compactMap { s in frets[s - 1].map { GuitarNote(string: s, fret: $0) } } }
    public var midiNotes: [Int] { (1...6).reversed().compactMap { s in frets[s - 1].map { MusicTheory.standardTuning[s - 1] + $0 } } }
    public var bassMIDI: Int { midiNotes.min() ?? 0 }
    public var soundingStrings: Int { frets.compactMap { $0 }.count }
    public var lowestFret: Int { frets.compactMap { $0 }.filter { $0 > 0 }.min() ?? 0 }
    public var fretSpan: Int { (frets.compactMap { $0 }.max() ?? 0) - lowestFret }
    public var fretPositions: [FretPosition] {
        let pcs = chord.pitchClasses, names = chord.noteNames, degrees = chord.degrees
        return positions.compactMap { position in
            guard let fret = position.fret else { return nil }
            let midi = MusicTheory.standardTuning[position.string - 1] + fret
            guard let index = pcs.firstIndex(of: midi % 12) else { return nil }
            return FretPosition(string: position.string, fret: fret, midi: midi, pitchClass: midi % 12,
                                isRoot: midi % 12 == chord.root.rawValue, isBlue: false, degree: degrees[index], name: names[index])
        }
    }
    public var fingeringDescription: String {
        let strings = (1...6).reversed().map { s -> String in
            guard let fret = frets[s - 1] else { return "\(s)弦×" }
            return fret == 0 ? "\(s)弦空弦" : "\(s)弦\(fret)品(\(fingers[s - 1] ?? 0)指)"
        }.joined(separator: "，")
        let barreText = barres.map { "\($0.finger)指在\($0.fret)品横按\($0.fromString)–\($0.toString)弦" }.joined(separator: "；")
        return strings + (barreText.isEmpty ? "。" : "；" + barreText + "。")
    }
}

public enum ChordLibraryError: Error, LocalizedError {
    case invalidOptions
    public var errorDescription: String? { "筛选范围无效：按弦须在 1–24 品，品差 0–23，弦数 1–6，手指数 0–4，且最小值不能大于最大值。" }
}

public enum ChordLibrary {
    public static let fingeringScope = "按法在标准六弦、每弦最多一个音、全部构成音均出现的条件下穷举。左手只用 1–4 指；一指按一个点或同品连续横按。横按可跨越更高品的按弦，不能跨越空弦、消音或更低品；不建模拇指、反手、手掌大小、弦距与关节弯曲。指法是几何候选，仍需真人试按。相同弦品只保留一种最少用指方案。"

    /// Check a simultaneous six-string grip with the same explicit finger model used
    /// by the library. This does not require its notes to form any particular chord.
    public static func canFinger(frets: [Int?], maximumSpan: Int = 4, maximumFingers: Int = 4) -> Bool {
        guard frets.count == 6, frets.allSatisfy({ $0 == nil || (0...24).contains($0!) }),
              (0...23).contains(maximumSpan), (0...4).contains(maximumFingers) else { return false }
        let pressed = frets.compactMap { $0 }.filter { $0 > 0 }
        guard (pressed.max() ?? 0) - (pressed.min() ?? 0) <= maximumSpan else { return false }
        return fingering(frets: frets, allowBarre: true, maximumFingers: maximumFingers) != nil
    }

    /// Exhaustive within the explicit model. There is no result cap or omitted chord tone.
    /// Cancellation throws rather than returning an incomplete result as a complete library.
    public static func voicings(for chord: ChordDefinition, options: ChordSearchOptions = .init(),
                                isCancelled: () -> Bool = { false }) throws -> [ChordVoicing] {
        guard (1...24).contains(options.minimumFret), (options.minimumFret...24).contains(options.maximumFret),
              (0...23).contains(options.maximumSpan), (1...6).contains(options.minimumStrings),
              (options.minimumStrings...6).contains(options.maximumStrings), (0...4).contains(options.maximumFingers) else {
            throw ChordLibraryError.invalidOptions
        }
        let required = chord.pitchClasses.reduce(0) { $0 | (1 << $1) }
        let choices: [[Int?]] = MusicTheory.standardTuning.map { open in
            var choices: [Int?] = [nil]
            if options.allowOpenStrings && required & (1 << (open % 12)) != 0 { choices.append(0) }
            for fret in options.minimumFret...options.maximumFret where required & (1 << ((open + fret) % 12)) != 0 { choices.append(fret) }
            return choices
        }
        var remainingMasks = Array(repeating: 0, count: 7)
        for string in (0..<6).reversed() {
            remainingMasks[string] = remainingMasks[string + 1] | choices[string].compactMap { $0 }.reduce(0) {
                $0 | (1 << ((MusicTheory.standardTuning[string] + $1) % 12))
            }
        }
        var frets = [Int?](repeating: nil, count: 6), results: [ChordVoicing] = []
        var visits = 0
        func visit(_ string: Int, count: Int, mask: Int, low: Int, high: Int, bass: Int) throws {
            visits += 1
            if visits % 512 == 0 && isCancelled() { throw CancellationError() }
            guard count <= options.maximumStrings, count + 6 - string >= options.minimumStrings,
                  (mask | remainingMasks[string]) == required else { return }
            if string == 6 {
                guard count >= options.minimumStrings, mask == required,
                      !options.rootInBass || bass % 12 == chord.root.rawValue,
                      let fingering = fingering(frets: frets, allowBarre: options.allowBarre, maximumFingers: options.maximumFingers) else { return }
                results.append(ChordVoicing(chord: chord, frets: frets, fingers: fingering.fingers,
                                            barres: fingering.barres, fingerCount: fingering.count))
                return
            }
            for fret in choices[string] {
                frets[string] = fret
                guard let fret else {
                    try visit(string + 1, count: count, mask: mask, low: low, high: high, bass: bass)
                    continue
                }
                let nextLow = fret > 0 ? min(low, fret) : low, nextHigh = max(high, fret)
                guard nextHigh == 0 || nextHigh - nextLow <= options.maximumSpan else { continue }
                let midi = MusicTheory.standardTuning[string] + fret
                try visit(string + 1, count: count + 1, mask: mask | (1 << (midi % 12)), low: nextLow, high: nextHigh, bass: min(bass, midi))
            }
        }
        if isCancelled() { throw CancellationError() }
        try visit(0, count: 0, mask: 0, low: 25, high: 0, bass: 128)
        results.sort { lhs, rhs in
            let left = rank(lhs), right = rank(rhs)
            if left != right { return left.lexicographicallyPrecedes(right) }
            return lhs.frets.map { $0 ?? -1 }.lexicographicallyPrecedes(rhs.frets.map { $0 ?? -1 })
        }
        if isCancelled() { throw CancellationError() }
        return results
    }

    private static func rank(_ voicing: ChordVoicing) -> [Int] {
        // Avoid making a sparse inversion with interior muted strings a beginner's
        // first recommendation merely because it uses one finger. All results remain.
        let sounding = (0..<6).filter { voicing.frets[$0] != nil }
        let interiorMutes = sounding.isEmpty ? 0 : sounding.last! - sounding.first! + 1 - sounding.count
        return [interiorMutes, voicing.bassMIDI % 12 == voicing.chord.root.rawValue ? 0 : 1,
                voicing.lowestFret, voicing.fingerCount, voicing.barres.count, voicing.fretSpan, -voicing.soundingStrings]
    }

    private struct Contact {
        let fret: Int
        let from: Int
        let to: Int
        let mask: Int
    }
    private struct Fingering {
        var fingers: [Int?]
        var barres: [ChordBarre]
        var count: Int
    }
    private static func fingering(frets: [Int?], allowBarre: Bool, maximumFingers: Int) -> Fingering? {
        let target = (0..<6).reduce(0) { $0 | ((frets[$1] ?? 0) > 0 ? 1 << $1 : 0) }
        var contacts: [Contact] = []
        for start in 0..<6 {
            guard let fret = frets[start], fret > 0 else { continue }
            contacts.append(Contact(fret: fret, from: start, to: start, mask: 1 << start))
            guard allowBarre, start < 5 else { continue }
            var mask = 1 << start
            for end in (start + 1)..<6 {
                guard let crossed = frets[end], crossed >= fret else { break }
                if crossed == fret {
                    mask |= 1 << end
                    contacts.append(Contact(fret: fret, from: start, to: end, mask: mask))
                }
            }
        }
        // Exact set cover of the at most six pressed points. A contact may pass under
        // a higher note, but two contacts never claim the same audible pressed point.
        contacts.sort {
            if $0.mask.nonzeroBitCount != $1.mask.nonzeroBitCount { return $0.mask.nonzeroBitCount > $1.mask.nonzeroBitCount }
            if $0.fret != $1.fret { return $0.fret < $1.fret }
            return $0.from < $1.from
        }
        var best: [Contact]?
        func cover(_ covered: Int, chosen: [Contact]) {
            if covered == target { if best == nil || chosen.count < best!.count { best = chosen }; return }
            guard chosen.count < maximumFingers, chosen.count + 1 < (best?.count ?? 7) else { return }
            let first = (target & ~covered).trailingZeroBitCount
            for contact in contacts where contact.mask & (1 << first) != 0 && contact.mask & covered == 0 {
                cover(covered | contact.mask, chosen: chosen + [contact])
            }
        }
        cover(0, chosen: [])
        guard let best else { return nil }
        let sorted = best.sorted { $0.fret == $1.fret ? $0.from > $1.from : $0.fret < $1.fret }
        var fingers = frets.map { $0 == 0 ? Optional(0) : nil }, barres: [ChordBarre] = []
        for (index, contact) in sorted.enumerated() {
            for string in 0..<6 where contact.mask & (1 << string) != 0 { fingers[string] = index + 1 }
            if contact.from != contact.to {
                barres.append(ChordBarre(finger: index + 1, fret: contact.fret, fromString: contact.from + 1, toString: contact.to + 1))
            }
        }
        return Fingering(fingers: fingers, barres: barres, count: best.count)
    }
}
