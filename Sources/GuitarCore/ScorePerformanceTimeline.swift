import Foundation

public struct ScoreLyricPhrase: Equatable, Sendable, Identifiable {
    public let startTick: Int
    /// The phrase is current in [startTick, endTick), including short internal gaps.
    public let endTick: Int
    public let text: String
    public var id: Int { startTick }
    public init(startTick: Int, endTick: Int, text: String) {
        self.startTick = startTick; self.endTick = endTick; self.text = text
    }
}

public struct ScoreChordCue: Equatable, Sendable, Identifiable {
    public let startTick: Int
    public let symbol: String
    public var id: Int { startTick }
    public init(startTick: Int, symbol: String) { self.startTick = startTick; self.symbol = symbol }
}

public struct ScorePerformanceContext: Equatable, Sendable {
    public let previousLyric: ScoreLyricPhrase?
    public let currentLyric: ScoreLyricPhrase?
    public let nextLyric: ScoreLyricPhrase?
    public let previousChord: ScoreChordCue?
    public let currentChord: ScoreChordCue?
    public let nextChord: ScoreChordCue?
    public init(previousLyric: ScoreLyricPhrase? = nil, currentLyric: ScoreLyricPhrase? = nil, nextLyric: ScoreLyricPhrase? = nil,
                previousChord: ScoreChordCue? = nil, currentChord: ScoreChordCue? = nil, nextChord: ScoreChordCue? = nil) {
        self.previousLyric = previousLyric; self.currentLyric = currentLyric; self.nextLyric = nextLyric
        self.previousChord = previousChord; self.currentChord = currentChord; self.nextChord = nextChord
    }
}

/// A derived view of existing event lyrics; it never changes the score or invents
/// word-level timing. Build once per score/voice change, then seek freely by tick.
public struct ScorePerformanceTimeline: Sendable {
    public let lyricPhrases: [ScoreLyricPhrase]
    public let chordCues: [ScoreChordCue]

    public init(score: GuitarScore, voice: ScoreVoice) {
        let capacity = score.timeSignature.ticks
        guard capacity > 0 else { lyricPhrases = []; chordCues = []; return }
        var lyricTokens: [LyricToken] = []
        var chordAtTick: [Int: ScoreChordCue] = [:]
        // A selected-voice marker wins at the same tick. Within one event there is
        // no timing for subsequent inline markers, so only the leftmost is a cue.
        let voiceOrder = [voice] + ScoreVoice.allCases.filter { $0 != voice }
        for (measureIndex, measure) in score.measures.enumerated() {
            let offset = measureIndex.multipliedReportingOverflow(by: capacity)
            guard !offset.overflow else { break }
            for sourceVoice in voiceOrder {
                let events = measure.events(for: sourceVoice).enumerated().sorted {
                    $0.element.startTick == $1.element.startTick ? $0.offset < $1.offset : $0.element.startTick < $1.element.startTick
                }
                for (_, event) in events {
                    guard let lyric = event.lyric, event.startTick >= 0, event.startTick < capacity,
                          event.endTick > event.startTick, event.endTick <= capacity else { continue }
                    let start = offset.partialValue.addingReportingOverflow(event.startTick)
                    let end = offset.partialValue.addingReportingOverflow(event.endTick)
                    guard !start.overflow, !end.overflow else { continue }
                    let parsed = Self.parse(lyric)
                    if let symbol = parsed.chord, chordAtTick[start.partialValue] == nil {
                        chordAtTick[start.partialValue] = ScoreChordCue(startTick: start.partialValue, symbol: symbol)
                    }
                    if sourceVoice == voice, !parsed.text.isEmpty || parsed.endsPhrase {
                        lyricTokens.append(LyricToken(start: start.partialValue, end: end.partialValue,
                                                      text: parsed.text, startsNewLine: parsed.startsNewLine,
                                                      endsPhrase: parsed.endsPhrase))
                    }
                }
            }
        }
        lyricPhrases = Self.phrases(from: lyricTokens, capacity: capacity)
        var cues: [ScoreChordCue] = [], previousKey: String?
        for tick in chordAtTick.keys.sorted() {
            let cue = chordAtTick[tick]!
            let key = cue.symbol.replacingOccurrences(of: "#", with: "♯").replacingOccurrences(of: "b", with: "♭")
            if key != previousKey { cues.append(cue); previousKey = key }
        }
        chordCues = cues
    }

    public func context(at tick: Int) -> ScorePerformanceContext {
        var previousLyric: ScoreLyricPhrase?, currentLyric: ScoreLyricPhrase?, nextLyric: ScoreLyricPhrase?
        if let index = Self.lastStarted(in: lyricPhrases, tick: tick, start: { $0.startTick }) {
            let phrase = lyricPhrases[index]
            if tick < phrase.endTick {
                currentLyric = phrase
                if index > 0 { previousLyric = lyricPhrases[index - 1] }
            } else { previousLyric = phrase }
            if index + 1 < lyricPhrases.count { nextLyric = lyricPhrases[index + 1] }
        } else { nextLyric = lyricPhrases.first }
        var previousChord: ScoreChordCue?, currentChord: ScoreChordCue?, nextChord: ScoreChordCue?
        if let index = Self.lastStarted(in: chordCues, tick: tick, start: { $0.startTick }) {
            currentChord = chordCues[index]
            if index > 0 { previousChord = chordCues[index - 1] }
            if index + 1 < chordCues.count { nextChord = chordCues[index + 1] }
        } else { nextChord = chordCues.first }
        return ScorePerformanceContext(previousLyric: previousLyric, currentLyric: currentLyric, nextLyric: nextLyric,
                                       previousChord: previousChord, currentChord: currentChord, nextChord: nextChord)
    }

    private struct LyricToken {
        let start: Int
        let end: Int
        let text: String
        let startsNewLine: Bool
        let endsPhrase: Bool
    }
    private static func phrases(from tokens: [LyricToken], capacity: Int) -> [ScoreLyricPhrase] {
        var result: [ScoreLyricPhrase] = []
        var draft: ScoreLyricPhrase?
        func finish() { if let draft { result.append(draft) }; draft = nil }
        for token in tokens {
            if let phrase = draft, token.startsNewLine || token.start - phrase.endTick >= capacity
                || token.start / capacity - phrase.startTick / capacity >= 4 { finish() }
            guard !token.text.isEmpty else { if token.endsPhrase { finish() }; continue }
            if let phrase = draft {
                draft = ScoreLyricPhrase(startTick: phrase.startTick, endTick: max(phrase.endTick, token.end), text: join(phrase.text, token.text))
            } else { draft = ScoreLyricPhrase(startTick: token.start, endTick: token.end, text: token.text) }
            // An event can contain a full sentence or several lines. Retain that
            // event as one fragment because its words have no separate timestamps.
            if token.endsPhrase { finish() }
        }
        finish()
        return result
    }

    private struct ParsedLyric {
        let text: String
        let chord: String?
        let startsNewLine: Bool
        let endsPhrase: Bool
    }
    private static func parse(_ source: String) -> ParsedLyric {
        var visible = "", chord: String?
        var cursor = source.startIndex
        let arrows: Set<Character> = ["↑", "↓", "↗", "↘", "⇑", "⇓", "⇧", "⇩"]
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == "[", let close = source[source.index(after: cursor)...].firstIndex(of: "]") {
                let contents = String(source[source.index(after: cursor)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let symbol = ScoreChordSymbol(contents) {
                    if chord == nil { chord = symbol.text }
                } else { visible += source[cursor...close] }
                cursor = source.index(after: close)
            } else {
                if !arrows.contains(character) { visible.append(character) }
                cursor = source.index(after: cursor)
            }
        }
        let lines = visible.components(separatedBy: .newlines).map { line in
            line.split(whereSeparator: \.isWhitespace).map(String.init).reduce("") { join($0, $1) }
        }.filter { !$0.isEmpty }
        // A removed chord/arrow-only line must not become an artificial lyric line
        // break. Explicit leading/trailing newlines still count.
        let startsNewLine = source.drop(while: { $0 == " " || $0 == "\t" }).first?.isNewline == true
        let endsNewLine = source.reversed().drop(while: { $0 == " " || $0 == "\t" }).first?.isNewline == true
        let endsPhrase = hasPhraseBoundary(lines.joined(separator: "\n")) || startsNewLine || endsNewLine
        return ParsedLyric(text: lines.joined(separator: "\n"), chord: chord, startsNewLine: startsNewLine, endsPhrase: endsPhrase)
    }

    private static func hasPhraseBoundary(_ text: String) -> Bool {
        let boundaries: Set<Character> = ["。", "！", "？", "，", "；", "：", "、", ".", "!", "?", ",", ";", ":"]
        return text.contains { $0.isNewline || boundaries.contains($0) }
    }

    private static func join(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        let hyphens: Set<Character> = ["-", "‐"]
        var prefix = left, suffix = right
        if let last = prefix.last, hyphens.contains(last), let first = suffix.first, first.isLetter || hyphens.contains(first) {
            prefix.removeLast()
            if let first = suffix.first, hyphens.contains(first) { suffix.removeFirst() }
            return prefix + suffix
        }
        if let first = suffix.first, hyphens.contains(first), prefix.last?.isLetter == true {
            suffix.removeFirst(); return prefix + suffix
        }
        let closing: Set<Character> = [".", ",", ";", ":", "!", "?", "，", "。", "；", "：", "！", "？", "、", ")", "]", "}", "》", "）", "」", "』", "】", "…", "'", "’"]
        let opening: Set<Character> = ["(", "[", "{", "《", "（", "「", "『", "【"]
        if isCJK(prefix.last!) || isCJK(suffix.first!) || closing.contains(suffix.first!) || opening.contains(prefix.last!) {
            return prefix + suffix
        }
        return prefix + " " + suffix
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3400...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value)
                || (0x20000...0x3134F).contains(value) || (0x3040...0x30FF).contains(value)
                || (0xAC00...0xD7AF).contains(value)
        }
    }

    private static func lastStarted<Item>(in items: [Item], tick: Int, start: (Item) -> Int) -> Int? {
        var lower = 0, upper = items.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if start(items[middle]) <= tick { lower = middle + 1 } else { upper = middle }
        }
        return lower == 0 ? nil : lower - 1
    }
}
