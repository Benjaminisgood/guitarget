import Foundation

/// A name the chord recognizer can give to one moment of sound. Decoder states are
/// root-position sonorities; a heard bass note is attached afterwards, so an inverted
/// voicing never splits the posterior between "C" and "C/E".
public enum RecognizedChord: Hashable, Sendable {
    case none
    case singleNote(PitchClass)
    /// Root and fifth only, the ambiguous major/minor "5" chord.
    case powerChord(PitchClass)
    case chord(ChordDefinition, bass: PitchClass?)

    public var root: PitchClass? {
        switch self {
        case .none: return nil
        case .singleNote(let pitchClass), .powerChord(let pitchClass): return pitchClass
        case .chord(let definition, _): return definition.root
        }
    }
    public var definition: ChordDefinition? {
        if case .chord(let definition, _) = self { return definition }
        return nil
    }
    public var bass: PitchClass? {
        if case .chord(_, let bass) = self { return bass }
        return nil
    }
    public var isChord: Bool { definition != nil }
    public var pitchClasses: [Int] {
        switch self {
        case .none: return []
        case .singleNote(let pitchClass): return [pitchClass.rawValue]
        case .powerChord(let pitchClass): return [pitchClass.rawValue, (pitchClass.rawValue + 7) % 12]
        case .chord(let definition, _): return definition.pitchClasses
        }
    }
    /// Short symbol such as "Am7", "C/E", "E5" or a bare note name for a single note.
    public var label: String {
        switch self {
        case .none: return "—"
        case .singleNote(let pitchClass): return pitchClass.displayName
        case .powerChord(let pitchClass): return pitchClass.displayName + "5"
        case .chord(let definition, let bass):
            guard let bass, bass != definition.root else { return definition.name }
            return definition.name + "/" + bass.displayName
        }
    }
    public var kindTitle: String {
        switch self {
        case .none: return "无和弦"
        case .singleNote: return "单音"
        case .powerChord: return "强力和弦（根音 + 五音）"
        case .chord(let definition, let bass):
            guard let bass, bass != definition.root else { return definition.kind.title }
            return definition.kind.title + " · 转位，低音 " + bass.displayName
        }
    }
    public var noteNames: [String] {
        switch self {
        case .none: return []
        case .singleNote(let pitchClass): return [pitchClass.displayName]
        case .powerChord(let pitchClass): return [pitchClass.displayName, PitchClass(midi: pitchClass.rawValue + 7).displayName]
        case .chord(let definition, _): return definition.noteNames
        }
    }
    public var withoutBass: RecognizedChord {
        if case .chord(let definition, _) = self { return .chord(definition, bass: nil) }
        return self
    }
    /// A heard bass that is a chord tone other than the root names an inversion.
    /// Any other bass leaves the symbol unchanged; the frame still reports the note.
    public func attachingBass(_ heard: PitchClass?) -> RecognizedChord {
        guard case .chord(let definition, _) = self else { return self }
        guard let heard, heard != definition.root, definition.pitchClasses.contains(heard.rawValue) else {
            return .chord(definition, bass: nil)
        }
        return .chord(definition, bass: heard)
    }
}

/// Unit-length pitch-class profile of one decoder state.
public struct ChordTemplate: Equatable, Sendable {
    public let chord: RecognizedChord
    public let profile: [Double]
    public init(chord: RecognizedChord) {
        self.chord = chord
        var profile = [Double](repeating: 0, count: 12)
        for pitchClass in chord.pitchClasses { profile[pitchClass] = 1 }
        let norm = sqrt(profile.reduce(0) { $0 + $1 * $1 })
        self.profile = norm > 0 ? profile.map { $0 / norm } : profile
    }
}

public enum ChordVocabulary {
    /// No chord, every ChordKind on every root, then power chords and single notes.
    public static let standard: [ChordTemplate] = {
        var templates = [ChordTemplate(chord: .none)]
        for root in PitchClass.allCases {
            for kind in ChordKind.allCases { templates.append(ChordTemplate(chord: .chord(ChordDefinition(root: root, kind: kind), bass: nil))) }
            templates.append(ChordTemplate(chord: .powerChord(root)))
            templates.append(ChordTemplate(chord: .singleNote(root)))
        }
        return templates
    }()
}

public struct ChordCandidate: Equatable, Sendable {
    public let chord: RecognizedChord
    /// Template fit plus the bass bonus in the current frame, before temporal smoothing.
    public let score: Double
    public init(chord: RecognizedChord, score: Double) { self.chord = chord; self.score = score }
}

/// One salient note of the approximate transcription, relative to the loudest note.
public struct DetectedNote: Equatable, Sendable, Identifiable {
    public let midi: Int
    public let salience: Double
    public init(midi: Int, salience: Double) { self.midi = midi; self.salience = salience }
    public var id: Int { midi }
    public var name: String { MusicTheory.noteName(midi: midi) }
}

public struct ChordFrame: Equatable, Sendable {
    /// Monotonic host time of the analysis window centre, as for PitchFrame.
    public var timestamp: Double
    public var chord: RecognizedChord
    /// Filtered posterior probability of the decoded state after temporal smoothing.
    public var confidence: Double
    /// Cosine similarity between the current chroma and the decoded template, 0–1.
    public var fit: Double
    public var candidates: [ChordCandidate]
    /// Twelve treble pitch-class saliences, unit length; index 0 is C.
    public var chroma: [Double]
    /// Twelve bass-weighted saliences normalised to sum 1 when any bass energy exists.
    public var bassChroma: [Double]
    public var notes: [DetectedNote]
    /// Estimated deviation of the instrument from the 12-TET grid, in cents.
    public var tuningCents: Double
    public var rms: Double
    /// Time the decoded state has been held continuously.
    public var heldDuration: Double
    /// The most recent independently measured attack, as for PitchFrame.
    public var onsetTimestamp: Double?
    public init(timestamp: Double, chord: RecognizedChord, confidence: Double, fit: Double, candidates: [ChordCandidate] = [],
                chroma: [Double] = [Double](repeating: 0, count: 12), bassChroma: [Double] = [Double](repeating: 0, count: 12),
                notes: [DetectedNote] = [], tuningCents: Double = 0, rms: Double = 0, heldDuration: Double = 0, onsetTimestamp: Double? = nil) {
        self.timestamp = timestamp; self.chord = chord; self.confidence = confidence; self.fit = fit; self.candidates = candidates
        self.chroma = chroma; self.bassChroma = bassChroma; self.notes = notes; self.tuningCents = tuningCents; self.rms = rms
        self.heldDuration = heldDuration; self.onsetTimestamp = onsetTimestamp
    }
    public var label: String { chord.label }
    public var isStable: Bool { heldDuration >= 0.25 }
}

public struct ChordDecision: Equatable, Sendable {
    public let index: Int
    public let chord: RecognizedChord
    public let posterior: Double
    public let fit: Double
    public let score: Double
    public let candidates: [ChordCandidate]
    public let heldDuration: Double
}

/// Online hidden Markov decoding of chroma frames: a von Mises–Fisher style emission
/// (cosine fit sharpened by `sharpness`, plus a bass bonus for the root) and a sticky
/// transition matrix. Forward filtering keeps a true posterior, so a decision only
/// changes once the new evidence outweighs the switch penalty; no lookahead is used.
public struct ChordDecoder: Sendable {
    public let templates: [ChordTemplate]
    public var sharpness: Double
    public var bassWeight: Double
    public var noChordScore: Double
    public var switchProbability: Double
    /// Fraction of the posterior returned to the uniform prior per silent frame.
    public var silenceRelaxation: Double
    /// A gap longer than this restarts the held-duration clock.
    public var continuityGap = 0.6
    private var posterior: [Double]
    private var currentIndex: Int?
    private var currentSince = 0.0
    private var lastTimestamp: Double?

    public init(templates: [ChordTemplate] = ChordVocabulary.standard, sharpness: Double = 18, bassWeight: Double = 0.35,
                noChordScore: Double = 0.82, switchProbability: Double = 0.03, silenceRelaxation: Double = 0.15) {
        self.templates = templates; self.sharpness = sharpness; self.bassWeight = bassWeight
        self.noChordScore = noChordScore; self.switchProbability = switchProbability; self.silenceRelaxation = silenceRelaxation
        posterior = [Double](repeating: 1 / Double(max(1, templates.count)), count: templates.count)
    }

    public var current: RecognizedChord? { currentIndex.map { templates[$0].chord } }

    public mutating func reset() {
        posterior = [Double](repeating: 1 / Double(max(1, templates.count)), count: templates.count)
        currentIndex = nil; currentSince = 0; lastTimestamp = nil
    }

    /// Silence carries no chord evidence; it only lets an old belief fade.
    public mutating func observeSilence(at timestamp: Double) {
        let uniform = 1 / Double(max(1, templates.count))
        let keep = 1 - min(1, max(0, silenceRelaxation))
        for index in posterior.indices { posterior[index] = keep * posterior[index] + (1 - keep) * uniform }
        lastTimestamp = timestamp
    }

    /// Frame scores in the emission's linear domain: cosine fit of the treble chroma plus
    /// `bassWeight` times the fraction of bass energy on the state's root.
    public static func scores(chroma: [Double], bassChroma: [Double], templates: [ChordTemplate], bassWeight: Double, noChordScore: Double) -> [Double] {
        precondition(chroma.count == 12 && bassChroma.count == 12)
        let norm = sqrt(chroma.reduce(0) { $0 + $1 * $1 })
        let unit = norm > 0 ? chroma.map { $0 / norm } : chroma
        let bassTotal = bassChroma.reduce(0, +)
        let bass = bassTotal > 0 ? bassChroma.map { max(0, $0) / bassTotal } : [Double](repeating: 0, count: 12)
        return templates.map { template in
            guard template.chord != .none else { return noChordScore }
            var fit = 0.0
            for index in 0..<12 { fit += unit[index] * template.profile[index] }
            let bonus = template.chord.root.map { bass[$0.rawValue] } ?? 0
            return fit + bassWeight * bonus
        }
    }

    public mutating func decode(chroma: [Double], bassChroma: [Double], timestamp: Double) -> ChordDecision {
        let scores = Self.scores(chroma: chroma, bassChroma: bassChroma, templates: templates, bassWeight: bassWeight, noChordScore: noChordScore)
        let count = templates.count
        let switching = min(0.5, max(0, switchProbability))
        let spread = count > 1 ? switching / Double(count - 1) : 0
        let best = scores.max() ?? 0
        var total = 0.0
        var updated = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let prior = (1 - switching) * posterior[index] + spread * (1 - posterior[index])
            let value = prior * exp(sharpness * (scores[index] - best))
            updated[index] = value; total += value
        }
        if total > 0 { for index in 0..<count { updated[index] /= total } }
        else { updated = [Double](repeating: 1 / Double(count), count: count) }
        posterior = updated
        var decoded = 0
        for index in 1..<count where posterior[index] > posterior[decoded] { decoded = index }
        if let last = lastTimestamp, timestamp - last > continuityGap { currentIndex = nil }
        if currentIndex != decoded { currentIndex = decoded; currentSince = timestamp }
        lastTimestamp = timestamp
        let fit = Self.cosine(chroma, templates[decoded].profile)
        let ranked = scores.indices.filter { templates[$0].chord != .none }.sorted { scores[$0] > scores[$1] }.prefix(3)
        return ChordDecision(index: decoded, chord: templates[decoded].chord, posterior: posterior[decoded], fit: fit, score: scores[decoded],
                             candidates: ranked.map { ChordCandidate(chord: templates[$0].chord, score: scores[$0]) },
                             heldDuration: max(0, timestamp - currentSince))
    }

    private static func cosine(_ chroma: [Double], _ profile: [Double]) -> Double {
        let norm = sqrt(chroma.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return 0 }
        var dot = 0.0
        for index in 0..<12 { dot += chroma[index] * profile[index] }
        return min(1, max(0, dot / norm))
    }
}
