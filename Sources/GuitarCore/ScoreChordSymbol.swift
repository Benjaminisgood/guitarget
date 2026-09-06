import Foundation

/// One complete chord label, not a search within prose. The caller decides whether
/// a valid label occurs in chord markup; ordinary text must not be stripped first.
public struct ScoreChordSymbol: Equatable, Sendable {
    /// Only surrounding whitespace is removed. Display spelling and aliases are preserved.
    public let text: String
    public let rootPitchClass: Int
    private let rootLetter: Int
    private let usesLowercaseNumeral: Bool
    private let degreeSuffix: String
    private let slashBass: String

    public init?(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 64,
              !cleaned.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        var parts = cleaned.components(separatedBy: "/")
        var bass = ""
        // A numeric /9 belongs to a 6/9 quality; a final spelled note is a slash bass.
        if parts.count > 1, let last = parts.last, let note = Self.readRoot(last), note.remainder.isEmpty {
            bass = "/" + last
            parts.removeLast()
        }
        let chord = parts.joined(separator: "/")
        guard let root = Self.readRoot(chord), let quality = Self.qualities[root.remainder] else { return nil }
        self.text = cleaned
        rootPitchClass = root.pitchClass; rootLetter = root.letter
        usesLowercaseNumeral = quality.lowercase; degreeSuffix = quality.suffix; slashBass = bass
    }

    /// The degree reference is the selected major or natural-minor scale. Root letters
    /// retain the distinction between e.g. F-sharp (#IV) and G-flat (bV) in C.
    /// A slash bass stays a spelled note; no unsupported figured-bass inversion is inferred.
    public func romanNumeral(tonic: PitchClass, minor: Bool) -> String {
        let degree = (rootLetter - tonic.letter + 7) % 7
        let intervals = minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        let expectedPitchClass = (tonic.rawValue + intervals[degree]) % 12
        let alteration = (rootPitchClass - expectedPitchClass + 18) % 12 - 6
        let accidental = String(repeating: alteration < 0 ? "♭" : "♯", count: abs(alteration))
        let numeral = ["I", "II", "III", "IV", "V", "VI", "VII"][degree]
        return accidental + (usesLowercaseNumeral ? numeral.lowercased() : numeral) + degreeSuffix + slashBass
    }

    private struct Root {
        let letter: Int
        let pitchClass: Int
        let remainder: String
    }
    private static func readRoot(_ text: String) -> Root? {
        let characters = Array(text)
        guard let first = characters.first, let letter = Array("CDEFGAB").firstIndex(of: first) else { return nil }
        var index = 1, alteration = 0
        if index < characters.count, characters[index] == "♮" { index += 1 }
        else if index < characters.count, let firstAlteration = accidental(characters[index]) {
            alteration = firstAlteration; index += 1
            if index < characters.count, accidental(characters[index]) == firstAlteration {
                alteration += firstAlteration; index += 1
            }
        }
        let pitchClass = ([0, 2, 4, 5, 7, 9, 11][letter] + alteration + 12) % 12
        return Root(letter: letter, pitchClass: pitchClass, remainder: String(characters.dropFirst(index)))
    }
    private static func accidental(_ character: Character) -> Int? {
        switch character { case "#", "♯": return 1; case "b", "♭": return -1; default: return nil }
    }

    private struct Quality: Sendable {
        let lowercase: Bool
        let suffix: String
    }
    /// A closed vocabulary prevents words such as "Amor" or "Bridge" from becoming chords.
    /// Unsupported extensions are rejected rather than assigned a guessed quality.
    private static let qualities: [String: Quality] = {
        var result: [String: Quality] = [:]
        func add(_ token: String, lowercase: Bool = false, suffix: String) {
            result[token] = Quality(lowercase: lowercase, suffix: suffix)
        }
        add("", suffix: "")
        for number in ["5", "6", "7", "9", "11", "13", "6/9", "69"] {
            add(number, suffix: number == "69" ? "6/9" : number)
        }
        for prefix in ["maj", "Maj", "M", "Δ", "△"] {
            for number in ["", "7", "9", "11", "13"] { add(prefix + number, suffix: number.isEmpty ? "" : "maj" + number) }
        }
        for prefix in ["m", "min", "mi", "-", "−"] {
            for number in ["", "6", "7", "9", "11", "13", "6/9", "69"] {
                add(prefix + number, lowercase: true, suffix: number == "69" ? "6/9" : number)
            }
            for major in ["maj", "Maj", "M", "Δ", "△"] {
                for number in ["7", "9"] {
                    add(prefix + major + number, lowercase: true, suffix: "maj" + number)
                    add(prefix + "(" + major + number + ")", lowercase: true, suffix: "maj" + number)
                }
            }
        }
        for prefix in ["dim", "°", "o"] {
            for number in ["", "7"] { add(prefix + number, lowercase: true, suffix: "°" + number) }
        }
        for prefix in ["aug", "+"] {
            for number in ["", "7", "9"] { add(prefix + number, suffix: "+" + number) }
        }
        for suspended in ["sus", "sus2", "sus4"] {
            let canonical = suspended == "sus" ? "sus4" : suspended
            for number in ["", "7", "9", "13"] { add(number + suspended, suffix: number + canonical) }
        }
        for number in ["2", "4", "6", "9", "11", "13"] {
            add("add" + number, suffix: "add" + number)
            add("(add" + number + ")", suffix: "add" + number)
            for minorPrefix in ["m", "min", "-"] {
                add(minorPrefix + "add" + number, lowercase: true, suffix: "add" + number)
                add(minorPrefix + "(add" + number + ")", lowercase: true, suffix: "add" + number)
            }
        }
        // Common single alterations are explicit too; arbitrary suffix text is never accepted.
        for base in ["7", "9", "11", "13", "maj7", "maj9", "M7", "M9", "m7", "m9", "m11"] {
            guard let quality = result[base] else { continue }
            for alteration in ["b5", "#5", "b9", "#9", "#11", "b13"] {
                let display = alteration.replacingOccurrences(of: "b", with: "♭").replacingOccurrences(of: "#", with: "♯")
                for spelling in [alteration, display] {
                    add(base + spelling, lowercase: quality.lowercase, suffix: quality.suffix + display)
                    add(base + "(" + spelling + ")", lowercase: quality.lowercase, suffix: quality.suffix + display)
                }
            }
        }
        for symbol in ["ø", "ø7", "Ø", "Ø7"] { add(symbol, lowercase: true, suffix: "ø7") }
        for prefix in ["m", "min", "mi", "-", "−"] {
            for alteration in ["b5", "♭5"] {
                add(prefix + "7" + alteration, lowercase: true, suffix: "ø7")
                add(prefix + "7(" + alteration + ")", lowercase: true, suffix: "ø7")
            }
        }
        return result
    }()
}
