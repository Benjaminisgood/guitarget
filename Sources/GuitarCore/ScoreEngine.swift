import Foundation

public struct ScoreIssue: Identifiable, Equatable, Sendable {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    public var message: String
    public var measureIndex: Int?
    public var voice: ScoreVoice?
    public var eventID: UUID?
    public var id: String { "\(measureIndex ?? -1)-\(voice?.rawValue ?? "score")-\(eventID?.uuidString ?? "")-\(message)" }
    public init(_ message: String, severity: Severity = .error, measureIndex: Int? = nil, voice: ScoreVoice? = nil, eventID: UUID? = nil) {
        self.message = message; self.severity = severity; self.measureIndex = measureIndex; self.voice = voice; self.eventID = eventID
    }
}

public struct TickRange: Equatable, Sendable {
    public var startTick: Int
    public var endTick: Int
    public init(_ startTick: Int, _ endTick: Int) { self.startTick = startTick; self.endTick = endTick }
    public var ticks: Int {
        let result = endTick.subtractingReportingOverflow(startTick)
        return result.overflow ? (endTick >= startTick ? Int.max : Int.min) : result.partialValue
    }
}

public struct ScheduledNote: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var eventID: UUID
    public var voice: ScoreVoice
    public var note: GuitarNote
    public var midi: Int
    public var startTick: Int
    public var endTick: Int
    public var continuationIDs: [UUID]
    public var durationTicks: Int { endTick - startTick }
}

public enum ScoreScheduler {
    /// Per-note ties extend only their own string. Other notes in a chord retain their own durations.
    public static func notes(_ score: GuitarScore) -> [ScheduledNote] {
        guard score.tuning.count == 6, score.tuning.allSatisfy({ (0...127).contains($0) }), score.timeSignature.ticks > 0 else { return [] }
        let capacity = score.timeSignature.ticks
        guard !score.measures.count.multipliedReportingOverflow(by: capacity).overflow else { return [] }
        var result: [ScheduledNote] = []
        for voice in ScoreVoice.allCases {
            var pending: [Int: Int] = [:]
            for (measureIndex, measure) in score.measures.enumerated() {
                for event in measure.events(for: voice).sorted(by: { $0.startTick < $1.startTick }) {
                    guard event.startTick >= 0, event.endTick <= capacity else { continue }
                    let start = measureIndex * capacity + event.startTick
                    for note in event.notes where (1...6).contains(note.string) && (0...24).contains(note.fret) {
                        guard let midi = score.validMIDI(for: note) else { continue }
                        if let index = pending[note.string], result[index].endTick == start,
                           result[index].note.fret == note.fret {
                            result[index].endTick = start + event.rhythm.ticks
                            result[index].continuationIDs.append(note.id)
                            if !note.tieToNext { pending[note.string] = nil }
                        } else {
                            pending[note.string] = nil
                            result.append(ScheduledNote(id: note.id, eventID: event.id, voice: voice, note: note,
                                midi: midi, startTick: start, endTick: start + event.rhythm.ticks, continuationIDs: []))
                            if note.tieToNext { pending[note.string] = result.count - 1 }
                        }
                    }
                }
            }
        }
        return result.sorted { $0.startTick == $1.startTick ? $0.note.string < $1.note.string : $0.startTick < $1.startTick }
    }

    public static func restGaps(in measure: ScoreMeasure, voice: ScoreVoice, capacity: Int) -> [TickRange] {
        guard capacity > 0 else { return [] }
        var cursor = 0
        var gaps: [TickRange] = []
        for event in measure.events(for: voice).sorted(by: { $0.startTick < $1.startTick }) {
            if event.startTick > cursor { gaps.append(TickRange(cursor, min(capacity, event.startTick))) }
            cursor = max(cursor, event.endTick)
        }
        if cursor < capacity { gaps.append(TickRange(cursor, capacity)) }
        return gaps.filter { $0.ticks > 0 }
    }
}

public enum ScoreValidator {
    public static func validate(_ score: GuitarScore) -> [ScoreIssue] {
        var issues: [ScoreIssue] = []
        if score.version != 1 { issues.append(ScoreIssue("不支持文档版本 \(score.version)，当前支持版本 1。")) }
        if score.tuning.count != 6 || score.tuning.contains(where: { !(0...127).contains($0) }) {
            issues.append(ScoreIssue("调弦必须是从第 1 弦到第 6 弦的六个 MIDI 音高。"))
        }
        if !TimeSignature.supported.contains(score.timeSignature) { issues.append(ScoreIssue("仅支持 2/4、3/4、4/4 和 6/8 拍。")) }
        if !score.bpm.isFinite || !(20...300).contains(score.bpm) { issues.append(ScoreIssue("速度必须在 20–300 BPM 之间。")) }
        if score.measures.isEmpty { issues.append(ScoreIssue("曲谱至少需要一个小节。")) }
        // A malformed denominator, tuning, version, or tempo cannot participate in later arithmetic.
        guard issues.isEmpty else { return issues }
        let capacity = score.timeSignature.ticks
        guard !score.measures.count.multipliedReportingOverflow(by: capacity).overflow else { return [ScoreIssue("曲谱总时长超出整数 ticks 的表示范围。") ] }
        var identities = Set<UUID>()
        struct Entry { var start: Int; var end: Int; var measure: Int; var voice: ScoreVoice; var event: ScoreEvent; var note: GuitarNote }
        var entries: [Entry] = []
        for (index, measure) in score.measures.enumerated() {
            if !identities.insert(measure.id).inserted { issues.append(ScoreIssue("小节 ID 重复。", measureIndex: index)) }
            if measure.voices.count != 2 || Set(measure.voices.map(\.voice)) != Set(ScoreVoice.allCases) {
                issues.append(ScoreIssue("每小节必须恰好包含旋律、低音两个独立声部。", measureIndex: index))
            }
            for track in measure.voices {
                let sorted = track.events.sorted { $0.startTick < $1.startTick }
                var precedingEnd = 0
                for event in sorted {
                    func issue(_ text: String) -> ScoreIssue { ScoreIssue(text, measureIndex: index, voice: track.voice, eventID: event.id) }
                    if !identities.insert(event.id).inserted { issues.append(issue("事件 ID 重复。")) }
                    if event.startTick < 0 || event.endTick > capacity { issues.append(issue("事件超出第 \(index + 1) 小节容量 \(capacity) ticks；请缩短时值或拆分并延音。")) }
                    if event.startTick < precedingEnd { issues.append(issue("同一声部的节奏事件重叠；同拍和弦请放在同一个事件中。")) }
                    precedingEnd = max(precedingEnd, event.endTick)
                    if event.rhythm.dotted && event.rhythm.triplet { issues.append(issue("附点与三连音不能同时启用。")) }
                    if event.rhythm.triplet && event.rhythm.value != .eighth { issues.append(issue("首版仅支持八分音符三连音。")) }
                    if Set(event.notes.map(\.string)).count != event.notes.count { issues.append(issue("同一个和弦不能在同一根弦上放置两个音。")) }
                    for note in event.notes {
                        if !identities.insert(note.id).inserted { issues.append(issue("音符 ID 重复。")) }
                        if !(1...6).contains(note.string) || !(0...24).contains(note.fret) { issues.append(issue("音符必须位于第 1–6 弦、第 0–24 品。")) }
                        else if score.validMIDI(for: note) == nil { issues.append(issue("调弦加品位后的实际音高必须在 MIDI 0–127 内。")) }
                        if !note.velocity.isFinite || !(0...1).contains(note.velocity) { issues.append(issue("音符力度必须在 0–1 之间。")) }
                        if let target = note.targetFret, !(0...24).contains(target) { issues.append(issue("技巧目标品位必须在 0–24 品之间。")) }
                        else if let target = note.targetFret, (1...6).contains(note.string), score.tuning[note.string - 1] + target > 127 {
                            issues.append(issue("技巧目标的实际音高必须在 MIDI 0–127 内。"))
                        }
                        if let midi = score.validMIDI(for: note), (note.technique == .bendHalf && midi > 126) || (note.technique == .bendFull && midi > 125) {
                            issues.append(issue("推弦后的实际音高必须在 MIDI 0–127 内。"))
                        }
                        if [.hammerOn, .pullOff, .slide].contains(note.technique) && note.targetFret == nil { issues.append(issue("击弦、勾弦和滑音需要指定目标品位。")) }
                        if note.technique == .hammerOn, let target = note.targetFret, target <= note.fret { issues.append(issue("击弦目标必须高于起始品位。")) }
                        if note.technique == .pullOff, let target = note.targetFret, target >= note.fret { issues.append(issue("勾弦目标必须低于起始品位。")) }
                        if note.technique == .deadNote && note.tieToNext { issues.append(issue("死音不能使用持续延音。")) }
                        if event.startTick >= 0 && event.endTick <= capacity {
                            entries.append(Entry(start: index * capacity + event.startTick, end: index * capacity + event.endTick, measure: index, voice: track.voice, event: event, note: note))
                        }
                    }
                }
            }
        }
        for string in 1...6 {
            let onString = entries.filter { $0.note.string == string }.sorted { $0.start < $1.start }
            var active: [Entry] = []
            for entry in onString {
                active.removeAll { $0.end <= entry.start }
                if active.contains(where: { $0.voice != entry.voice }) {
                    issues.append(ScoreIssue("第 \(string) 弦持续音与另一声部冲突；一根弦不能同时演奏两个音。", measureIndex: entry.measure, voice: entry.voice, eventID: entry.event.id))
                }
                active.append(entry)
                if entry.note.tieToNext {
                    let targets = onString.filter { $0.voice == entry.voice && $0.start == entry.end && $0.note.fret == entry.note.fret }
                    if targets.count != 1 {
                        issues.append(ScoreIssue("延音尚未连接：需要同声部、同弦同品、紧接当前时值的下一个音。", severity: .warning, measureIndex: entry.measure, voice: entry.voice, eventID: entry.event.id))
                    } else if targets[0].note.technique != .none {
                        issues.append(ScoreIssue("延音续音不能同时重新触发演奏技巧。", measureIndex: targets[0].measure, voice: entry.voice, eventID: targets[0].event.id))
                    }
                }
            }
        }
        return issues
    }
}

public enum ScoreFileError: LocalizedError {
    case invalid([ScoreIssue])
    case malformed(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let issues): return issues.map(\.message).joined(separator: "\n")
        case .malformed(let description): return "无法读取 Guitarget 文档：\(description)"
        }
    }
}

public enum ScoreIO {
    private struct Header: Decodable { var version: Int }
    public static func encode(_ score: GuitarScore) throws -> Data {
        let issues = ScoreValidator.validate(score).filter { $0.severity == .error }
        guard issues.isEmpty else { throw ScoreFileError.invalid(issues) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(score)
    }
    public static func decode(_ data: Data) throws -> GuitarScore {
        let score: GuitarScore
        do {
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: data)
            guard header.version == 1 else { throw ScoreFileError.invalid([ScoreIssue("不支持文档版本 \(header.version)，当前支持版本 1。")]) }
            score = try decoder.decode(GuitarScore.self, from: data)
        }
        catch let error as ScoreFileError { throw error }
        catch { throw ScoreFileError.malformed(error.localizedDescription) }
        let issues = ScoreValidator.validate(score).filter { $0.severity == .error }
        guard issues.isEmpty else { throw ScoreFileError.invalid(issues) }
        return score
    }
}

/// Pure score history for non-UI integrations. Native windows use their own UndoManager.
public struct ScoreHistory: Sendable {
    public private(set) var score: GuitarScore
    private var undoStack: [GuitarScore] = []
    private var redoStack: [GuitarScore] = []
    public init(_ score: GuitarScore = GuitarScore()) { self.score = score }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public mutating func perform(_ change: (inout GuitarScore) throws -> Void) throws {
        var candidate = score; try change(&candidate)
        let issues = ScoreValidator.validate(candidate).filter { $0.severity == .error }
        guard issues.isEmpty else { throw ScoreFileError.invalid(issues) }
        guard candidate != score else { return }
        undoStack.append(score); score = candidate; redoStack.removeAll()
    }
    public mutating func undo() { guard let prior = undoStack.popLast() else { return }; redoStack.append(score); score = prior }
    public mutating func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(score); score = next }
}
