import Foundation

public enum ChordPracticeStyle: String, CaseIterable, Identifiable, Sendable {
    case diagram, listening, memory
    public var id: String { rawValue }
    public var title: String {
        switch self { case .diagram: return "看图演奏"; case .listening: return "听示范后演奏"; case .memory: return "限时记忆" }
    }
}

public enum ChordPracticeAssessment: String, CaseIterable, Identifiable, Sendable {
    case singleNotes, wholeChord, selfAssessment
    public var id: String { rawValue }
    public var title: String {
        switch self { case .singleNotes: return "逐弦单音判定"; case .wholeChord: return "整和弦识别判定"; case .selfAssessment: return "扫弦自评" }
    }
}

/// What the chord recogniser heard for one round. `matchesTarget` compares root and quality
/// only; the bass is reported separately so an inverted grip is feedback, not a failure.
public struct ChordRecognitionOutcome: Equatable, Sendable {
    public let heard: RecognizedChord
    public let matchesTarget: Bool
    public let heldDuration: Double
    public let timestamp: Double
    public init(heard: RecognizedChord, matchesTarget: Bool, heldDuration: Double, timestamp: Double) {
        self.heard = heard; self.matchesTarget = matchesTarget; self.heldDuration = heldDuration; self.timestamp = timestamp
    }
    public var description: String {
        guard matchesTarget else { return "识别为 \(heard.label)，与目标不同" }
        if let bass = heard.bass { return "识别为 \(heard.label) · 根音与性质正确，低音是 \(bass.displayName)" }
        return "识别为 \(heard.label) · 与目标一致"
    }
}

public enum ChordSelfRating: String, CaseIterable, Identifiable, Sendable {
    case confident, needsWork, skipped
    public var id: String { rawValue }
    public var title: String {
        switch self { case .confident: return "清晰、熟练"; case .needsWork: return "还需练习"; case .skipped: return "跳过本轮" }
    }
}

public struct ChordPracticeCard: Identifiable, Sendable {
    public let id: UUID
    public let chord: ChordDefinition
    public let voicing: ChordVoicing
    public let notes: [GuitarNote]
    public init(chord: ChordDefinition, voicing: ChordVoicing) {
        id = UUID(); self.chord = chord; self.voicing = voicing; notes = voicing.notes
    }
    public var targets: [PracticeTarget] {
        notes.enumerated().map { index, note in
            PracticeTarget(startTick: index * 960, endTick: (index + 1) * 960,
                           midi: MusicTheory.standardTuning[note.string - 1] + note.fret,
                           noteIDs: [note.id], requiresOnset: true)
        }
    }
}

public enum ChordPracticeDeckError: LocalizedError {
    case emptySelection, unavailable(String)
    public var errorDescription: String? {
        switch self { case .emptySelection: return "请至少选择一个根音和一种和弦性质。"; case .unavailable(let name): return "没有找到 \(name) 的可演奏按法。" }
    }
}

public enum ChordPracticeDeck {
    /// Shuffle a complete selected set before reusing a chord; never repeat an
    /// adjacent chord when the selected set contains more than one definition.
    public static func make<R: RandomNumberGenerator>(roots: [PitchClass], kinds: [ChordKind], rounds: Int, using random: inout R,
                                                     isCancelled: () -> Bool = { false }) throws -> [ChordPracticeCard] {
        let roots = Array(Set(roots)).sorted { $0.rawValue < $1.rawValue }
        let kinds = Array(Set(kinds)).filter { $0 == .major || $0 == .minor }.sorted { $0.rawValue < $1.rawValue }
        guard !roots.isEmpty, !kinds.isEmpty else { throw ChordPracticeDeckError.emptySelection }
        var choices: [(ChordDefinition, ChordVoicing)] = []
        for root in roots {
            for kind in kinds {
                if isCancelled() { throw CancellationError() }
                let chord = ChordDefinition(root: root, kind: kind)
                guard let voicing = try ChordLibrary.voicings(for: chord, isCancelled: isCancelled).first else { throw ChordPracticeDeckError.unavailable(chord.name) }
                choices.append((chord, voicing))
            }
        }
        var cards: [ChordPracticeCard] = []
        let count = min(40, max(1, rounds))
        while cards.count < count {
            var bag = choices.shuffled(using: &random)
            if bag.count > 1, cards.last?.chord == bag.first?.0 { bag.swapAt(0, 1) }
            for (chord, voicing) in bag.prefix(count - cards.count) { cards.append(ChordPracticeCard(chord: chord, voicing: voicing)) }
        }
        return cards
    }
}

public enum ChordPracticePhase: Equatable, Sendable {
    case idle, memorizing, awaitingDemonstration, listening, performing, review, finished
}

public struct ChordPracticeRoundResult: Identifiable, Sendable {
    public var id: UUID { card.id }
    public let card: ChordPracticeCard
    public let assessment: ChordPracticeAssessment
    public let automaticResults: [PracticeResult]
    /// Whole-chord recognition when that assessment was used; nil means the round was continued by hand.
    public let recognition: ChordRecognitionOutcome?
    public let rating: ChordSelfRating
    public let usedHint: Bool
    public let completedAt: Double
    public var automaticallyPassed: Int { automaticResults.filter { $0.outcome == .correct }.count }
    public var manuallySkipped: Int { automaticResults.filter { $0.outcome == .manual }.count }
    public var recognisedCorrectly: Bool { recognition?.matchesTarget == true }
}

/// Single-note assessment is a sequence of monophonic targets and does not measure the
/// simultaneous chord. Whole-chord assessment listens to the polyphonic recogniser instead:
/// it passes when the decoded root and quality match the card and are held briefly after a
/// fresh strum. Neither judges fingering comfort or strumming evenness; self-rating stays separate.
public struct ChordPracticeSession: Sendable {
    public private(set) var cards: [ChordPracticeCard] = []
    public private(set) var index = 0
    public private(set) var style: ChordPracticeStyle = .diagram
    public private(set) var assessment: ChordPracticeAssessment = .singleNotes
    public private(set) var phase: ChordPracticePhase = .idle
    public private(set) var engine = PracticeEngine()
    public private(set) var results: [ChordPracticeRoundResult] = []
    public private(set) var usedHint = false
    public private(set) var captureEnabled = false
    public private(set) var playbackBlocking = false
    public private(set) var memoryDeadline: Double?
    public private(set) var notice = ""
    /// Latest whole-chord recognition of the current round; a match ends the round.
    public private(set) var recognition: ChordRecognitionOutcome?
    /// A decoded chord must be held this long after a fresh strum before it counts.
    public var requiredChordHold = 0.3
    private var memorySeconds: Double = 5
    private var beforeDemonstration: ChordPracticePhase?
    private var acceptFramesAfter = Double.infinity

    public init() {}
    public var currentCard: ChordPracticeCard? { cards.indices.contains(index) ? cards[index] : nil }
    public var currentResult: ChordPracticeRoundResult? { results.last?.id == currentCard?.id ? results.last : nil }
    public var isActive: Bool { ![.idle, .finished].contains(phase) }
    public var diagramVisible: Bool { phase == .memorizing || phase == .review || usedHint || (style == .diagram && [.performing, .listening].contains(phase)) }
    public var canConsume: Bool { phase == .performing && assessment == .singleNotes && captureEnabled && !playbackBlocking }
    public var canConsumeChords: Bool { phase == .performing && assessment == .wholeChord && captureEnabled && !playbackBlocking }

    public mutating func start(cards: [ChordPracticeCard], style: ChordPracticeStyle, assessment: ChordPracticeAssessment, memorySeconds: Double = 5, at timestamp: Double) {
        self.cards = cards; self.style = style; self.assessment = assessment
        self.memorySeconds = memorySeconds.isFinite ? min(30, max(1, memorySeconds)) : 5
        index = 0; results = []; engine = PracticeEngine(); prepareRound(at: timestamp)
    }

    private mutating func prepareRound(at timestamp: Double) {
        usedHint = false; notice = ""; memoryDeadline = nil; beforeDemonstration = nil; engine = PracticeEngine(); recognition = nil
        guard currentCard != nil else { phase = .finished; return }
        switch style {
        case .diagram: beginPerforming(at: timestamp)
        case .listening: phase = .awaitingDemonstration
        case .memory: phase = .memorizing; memoryDeadline = timestamp + memorySeconds
        }
    }

    private mutating func beginPerforming(at timestamp: Double) {
        phase = .performing; memoryDeadline = nil; acceptFramesAfter = timestamp
        if assessment == .singleNotes, let card = currentCard {
            engine.start(targets: card.targets, mode: .waitForCorrect, at: timestamp)
            engine.setDemonstrating(!captureEnabled || playbackBlocking, at: timestamp)
        }
    }

    public mutating func update(at timestamp: Double) {
        if phase == .memorizing, let deadline = memoryDeadline, timestamp >= deadline { beginPerforming(at: timestamp) }
    }

    public mutating func setAudioContext(capturing: Bool, playbackBlocking: Bool, at timestamp: Double) {
        let wasAvailable = canConsume || canConsumeChords
        captureEnabled = capturing; self.playbackBlocking = playbackBlocking
        if phase == .performing, assessment == .singleNotes {
            engine.setDemonstrating(!canConsume, at: timestamp)
            if canConsume && !wasAvailable { acceptFramesAfter = timestamp }
        }
        if phase == .performing, assessment == .wholeChord, canConsumeChords, !wasAvailable { acceptFramesAfter = timestamp }
    }

    public mutating func beginDemonstration(at timestamp: Double) {
        guard [.awaitingDemonstration, .performing, .review].contains(phase) else { return }
        beforeDemonstration = phase; phase = .listening
        engine.setDemonstrating(true, at: timestamp)
    }

    public mutating func finishDemonstration(completed: Bool, at timestamp: Double) {
        guard phase == .listening, let previous = beforeDemonstration else { return }
        beforeDemonstration = nil
        if previous == .awaitingDemonstration {
            if completed { beginPerforming(at: timestamp) }
            else { phase = .awaitingDemonstration; notice = "示范未完成，请重新试听，或手动跳过示范。" }
        } else {
            phase = previous; acceptFramesAfter = timestamp
            engine.setDemonstrating(!canConsume, at: timestamp)
            if !completed { notice = "示范被中断；其他播放结束后再继续。" }
        }
    }

    public mutating func skipPreparation(at timestamp: Double) {
        guard [.memorizing, .awaitingDemonstration].contains(phase) else { return }
        usedHint = true; beginPerforming(at: timestamp)
    }

    public mutating func revealDiagram() { guard isActive else { return }; usedHint = true }

    public mutating func consume(_ observation: PitchObservation) {
        guard canConsume, observation.timestamp >= acceptFramesAfter,
              let onset = observation.onsetTimestamp, onset >= acceptFramesAfter else { return }
        engine.consume(observation)
        if engine.isFinished { phase = .review }
    }

    /// Whole-chord assessment. Frames analysed before the prompt, or without a strum after
    /// it, never count; demonstration tails therefore cannot pass a round. A wrong chord held
    /// as long as a right one is kept as feedback and the round waits for another strum.
    public mutating func consume(_ frame: ChordFrame) {
        guard canConsumeChords, let card = currentCard, frame.timestamp >= acceptFramesAfter,
              let onset = frame.onsetTimestamp, onset >= acceptFramesAfter, onset <= frame.timestamp else { return }
        guard frame.chord.pitchClasses.count >= 2, frame.heldDuration >= requiredChordHold - 0.0000001 else { return }
        let matches = frame.chord.definition == card.chord
        recognition = ChordRecognitionOutcome(heard: frame.chord, matchesTarget: matches, heldDuration: frame.heldDuration, timestamp: frame.timestamp)
        if matches { phase = .review }
    }

    /// Continue a whole-chord round by hand. The last chord heard stays as feedback; the round
    /// is recorded as continued manually, never as a pass.
    public mutating func skipRecognition(at timestamp: Double) {
        guard phase == .performing, assessment == .wholeChord, !playbackBlocking else { return }
        acceptFramesAfter = timestamp; phase = .review
    }

    public mutating func skipString(at timestamp: Double) {
        guard phase == .performing, assessment == .singleNotes, !playbackBlocking else { return }
        // A closed capture source must still allow a clearly marked manual skip.
        engine.setDemonstrating(false, at: timestamp)
        engine.manualAdvance(at: timestamp)
        acceptFramesAfter = timestamp
        engine.setDemonstrating(!captureEnabled, at: timestamp)
        if engine.isFinished { phase = .review }
    }

    public mutating func rate(_ rating: ChordSelfRating, at timestamp: Double) {
        guard [.performing, .review].contains(phase), currentResult == nil, let card = currentCard else { return }
        results.append(ChordPracticeRoundResult(card: card, assessment: assessment, automaticResults: engine.results,
                                                recognition: assessment == .wholeChord ? recognition : nil, rating: rating, usedHint: usedHint, completedAt: timestamp))
        engine.stop(); phase = .review
    }

    public mutating func next(at timestamp: Double) {
        guard phase == .review, currentResult != nil else { return }
        index += 1; prepareRound(at: timestamp)
    }

    public mutating func stop() { engine.stop(); phase = .finished; memoryDeadline = nil; beforeDemonstration = nil }
}
