import Foundation

public let ticksPerQuarter = 960

public enum ScoreVoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case melody, bass
    public var id: String { rawValue }
    public var title: String { self == .melody ? "旋律" : "低音" }
}

public enum NoteValue: Int, Codable, CaseIterable, Identifiable, Sendable {
    case whole = 1, half = 2, quarter = 4, eighth = 8, sixteenth = 16, thirtySecond = 32
    public var id: Int { rawValue }
    public var ticks: Int { 3840 / rawValue }
    public var title: String { "1/\(rawValue)" }
}

public struct Rhythm: Codable, Equatable, Sendable {
    public var value: NoteValue
    public var dotted: Bool
    public var triplet: Bool
    public init(_ value: NoteValue = .quarter, dotted: Bool = false, triplet: Bool = false) {
        self.value = value; self.dotted = dotted; self.triplet = triplet
    }
    public var ticks: Int { value.ticks * (dotted ? 3 : 2) / 2 * (triplet ? 2 : 3) / 3 }
}

public struct TimeSignature: Codable, Equatable, Hashable, Sendable {
    public var numerator: Int
    public var denominator: Int
    public init(_ numerator: Int = 4, _ denominator: Int = 4) { self.numerator = numerator; self.denominator = denominator }
    /// Unsupported external values have no capacity; validation reports them before timing arithmetic.
    public var ticks: Int {
        switch (numerator, denominator) {
        case (2,4): return 1920
        case (3,4), (6,8): return 2880
        case (4,4): return 3840
        default: return 0
        }
    }
    public var title: String { "\(numerator)/\(denominator)" }
    public static let supported = [TimeSignature(2,4), TimeSignature(3,4), TimeSignature(4,4), TimeSignature(6,8)]
}

public enum GuitarTechnique: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, hammerOn, pullOff, slide, bendHalf, bendFull, vibrato, palmMute, deadNote
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "普通拨弦"
        case .hammerOn: return "击弦 H"
        case .pullOff: return "勾弦 P"
        case .slide: return "滑音 /"
        case .bendHalf: return "半音推弦 ½"
        case .bendFull: return "全音推弦 1"
        case .vibrato: return "揉弦 ~"
        case .palmMute: return "闷音 P.M."
        case .deadNote: return "死音 ×"
        }
    }
}

public struct GuitarNote: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// 1 = high E, 6 = low E.
    public var string: Int
    public var fret: Int
    public var velocity: Double
    public var technique: GuitarTechnique
    public var targetFret: Int?
    public var tieToNext: Bool
    public init(id: UUID = UUID(), string: Int, fret: Int, velocity: Double = 0.75, technique: GuitarTechnique = .none, targetFret: Int? = nil, tieToNext: Bool = false) {
        self.id = id; self.string = string; self.fret = fret; self.velocity = velocity
        self.technique = technique; self.targetFret = targetFret; self.tieToNext = tieToNext
    }
}

public struct ScoreEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startTick: Int
    public var rhythm: Rhythm
    /// An empty notes array is an explicit rest.
    public var notes: [GuitarNote]
    /// A syllable or lyric phrase aligned to this event, shared by all notes in a chord.
    /// Missing or null lyrics decode as nil in existing version 1 documents.
    public var lyric: String?
    public init(id: UUID = UUID(), startTick: Int, rhythm: Rhythm = Rhythm(), notes: [GuitarNote] = [], lyric: String? = nil) {
        self.id = id; self.startTick = startTick; self.rhythm = rhythm; self.notes = notes; self.lyric = lyric
    }
    public var endTick: Int { let result = startTick.addingReportingOverflow(rhythm.ticks); return result.overflow ? Int.max : result.partialValue }
}

public struct VoiceTrack: Codable, Equatable, Sendable {
    public var voice: ScoreVoice
    public var events: [ScoreEvent]
    public init(voice: ScoreVoice, events: [ScoreEvent] = []) { self.voice = voice; self.events = events }
}

public struct ScoreMeasure: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var voices: [VoiceTrack]
    public init(id: UUID = UUID(), voices: [VoiceTrack] = [VoiceTrack(voice: .melody), VoiceTrack(voice: .bass)]) { self.id = id; self.voices = voices }
    public func events(for voice: ScoreVoice) -> [ScoreEvent] { voices.first(where: { $0.voice == voice })?.events ?? [] }
}

public struct GuitarScore: Codable, Equatable, Sendable {
    public var version: Int
    public var title: String
    public var tuning: [Int]
    public var timeSignature: TimeSignature
    public var bpm: Double
    public var measures: [ScoreMeasure]
    public init(version: Int = 1, title: String = "未命名曲谱", tuning: [Int] = [64,59,55,50,45,40], timeSignature: TimeSignature = TimeSignature(), bpm: Double = 80, measures: [ScoreMeasure] = [ScoreMeasure()]) {
        self.version = version; self.title = title; self.tuning = tuning
        self.timeSignature = timeSignature; self.bpm = bpm; self.measures = measures
    }
    public var totalTicks: Int {
        let product = measures.count.multipliedReportingOverflow(by: timeSignature.ticks)
        return product.overflow ? Int.max : product.partialValue
    }
    /// Invalid in-memory notes return nil. Native document reads reject these before display/playback.
    public func validMIDI(for note: GuitarNote) -> Int? {
        guard tuning.count == 6, (1...6).contains(note.string), (0...24).contains(note.fret) else { return nil }
        let open = tuning[note.string - 1]
        guard (0...127).contains(open) else { return nil }
        let midi = open + note.fret
        return (0...127).contains(midi) ? midi : nil
    }
    /// -1 is outside the supported MIDI domain and denotes an invalid in-memory note.
    public func midi(for note: GuitarNote) -> Int { validMIDI(for: note) ?? -1 }

    /// Learning views regenerate document IDs during ordinary SwiftUI redraws. Only a change to
    /// score content should cancel an active practice; persisted document equality still includes IDs.
    public func hasSameContent(as other: GuitarScore) -> Bool {
        guard measures.count == other.measures.count else { return false }
        var comparison = self
        for measure in comparison.measures.indices {
            guard comparison.measures[measure].voices.count == other.measures[measure].voices.count else { return false }
            comparison.measures[measure].id = other.measures[measure].id
            for voice in comparison.measures[measure].voices.indices {
                guard comparison.measures[measure].voices[voice].events.count == other.measures[measure].voices[voice].events.count else { return false }
                for event in comparison.measures[measure].voices[voice].events.indices {
                    let target = other.measures[measure].voices[voice].events[event]
                    guard comparison.measures[measure].voices[voice].events[event].notes.count == target.notes.count else { return false }
                    comparison.measures[measure].voices[voice].events[event].id = target.id
                    for note in target.notes.indices {
                        comparison.measures[measure].voices[voice].events[event].notes[note].id = target.notes[note].id
                    }
                }
            }
        }
        return comparison == other
    }
}
