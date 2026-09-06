import SwiftUI
import AppKit
import GuitarCore
import GuitarAudio
import OSLog

private let editorUndoLogger = Logger(subsystem: "com.guitarget.mac", category: "EditorUndo")

@MainActor
final class ScoreEditorState: ObservableObject {
    @Published var measureIndex = 0
    @Published var voice: ScoreVoice = .melody {
        didSet {
            if voice != oldValue {
                pendingDigit = nil
                synchronizeSelectionProperties()
                keyboardFocusToken = UUID()
            }
        }
    }
    @Published var string = 1
    @Published var tick = 0
    @Published private(set) var hasEditingSelection = true
    @Published private(set) var playbackPositionTick = 0
    @Published var rhythm = Rhythm()
    @Published var technique: GuitarTechnique = .none
    @Published var targetFret = 5
    @Published var error: String?
    @Published var loopEnabled = false
    @Published var loopStart = 1
    @Published var loopEnd = 1
    @Published var inspectorVisible = true
    @Published var zoom: Double = 1
    @Published var helpVisible = false
    @Published var keyboardFocusToken = UUID()
    let owner = "score-\(UUID().uuidString)"
    var auditionOwner: String { owner + "-preview" }
    var binding: Binding<GuitarScoreDocument>?
    // These inverses belong to the score editor. FileDocument's window manager
    // also performs delayed save/dirty bookkeeping, so sharing that manager
    // would let an inverse document write erase our redo stack. Score text fields
    // use the same editor history through their own local native responders.
    var undoManager: UndoManager? = UndoManager()
    var audio: AudioService?
    // FileDocument's Binding can retain the value from its SwiftUI render. Keep
    // unacknowledged writes only until the next render supplies that value.
    private var pendingScore: GuitarScore?
    private var pendingDigit: (digit: Int, time: TimeInterval, measure: Int, voice: ScoreVoice, string: Int, tick: Int)?
    var score: GuitarScore { pendingScore ?? binding?.wrappedValue.score ?? GuitarScore() }
    var absoluteTick: Int { measureIndex * score.timeSignature.ticks + tick }
    var selectedEvent: ScoreEvent? {
        guard hasEditingSelection else { return nil }
        return score.measures[safe: measureIndex]?.events(for: voice).first { $0.startTick == tick }
    }
    var selectedNote: GuitarNote? { selectedEvent?.notes.first { $0.string == string } }
    var issues: [ScoreIssue] { ScoreValidator.validate(score) }
    /// The audio clock belongs to this window only during its score transport.
    /// Preview notes and another document never replace its stored start point.
    var displayTick: Int {
        if let audio, audio.ownerID == owner, audio.isPlaying || audio.isPaused {
            return boundedPlaybackTick(audio.currentTick)
        }
        return boundedPlaybackTick(playbackPositionTick)
    }

    private func boundedPlaybackTick(_ value: Int) -> Int {
        min(max(0, value), max(0, score.totalTicks - 1))
    }

    func playbackNotes(at absoluteTick: Int, mutedVoices: Set<ScoreVoice>) -> [GuitarNote] {
        ScoreScheduler.notes(score).filter {
            !mutedVoices.contains($0.voice) && $0.startTick <= absoluteTick && absoluteTick < $0.endTick
        }.map(\.note)
    }

    func audition(string: Int, fret: Int) {
        guard let audio else { return }
        if audio.ownerID == owner {
            if audio.isPlaying { audio.pause() }
            playbackPositionTick = boundedPlaybackTick(audio.currentTick)
        }
        audio.preview(notes: [GuitarNote(string: string, fret: fret)], tuning: score.tuning, owner: auditionOwner)
    }

    func connect(_ binding: Binding<GuitarScoreDocument>, undoManager: UndoManager?, audio: AudioService,
                 synchronizeSelection: Bool = true) {
        refreshDocumentBinding(binding, synchronizeSelection: synchronizeSelection)
        // Do not adopt the FileDocument environment's bookkeeping manager.
        // Score text controls and score commands use ours, through local responders.
        self.audio = audio
    }

    func resolveWindowUndoManager(_ manager: UndoManager?) -> UndoManager {
        // The bridge deliberately keeps our score manager separate from the
        // NSWindow manager. Canvas and score text responders expose this manager.
        if undoManager == nil { undoManager = UndoManager() }
        return undoManager!
    }

    func performUndo() {
        logUndo("undo requested")
        undoManager?.undo()
        objectWillChange.send()
    }

    func performRedo() {
        logUndo("redo requested")
        undoManager?.redo()
        objectWillChange.send()
    }

    func stopOwnedPlayback() {
        if audio?.ownerID == owner || audio?.ownerID == auditionOwner { audio?.stop() }
    }

    private func logUndo(_ action: String) {
        guard let manager = undoManager else { editorUndoLogger.notice("\(action, privacy: .public): undoManager=nil"); return }
        editorUndoLogger.notice("\(action, privacy: .public): manager=\(String(describing: ObjectIdentifier(manager)), privacy: .public) type=\(String(describing: type(of: manager)), privacy: .public) canUndo=\(manager.canUndo) canRedo=\(manager.canRedo) enabled=\(manager.isUndoRegistrationEnabled) grouping=\(manager.groupingLevel) undoing=\(manager.isUndoing)")
    }

    func refreshDocumentBinding(_ binding: Binding<GuitarScoreDocument>, synchronizeSelection: Bool = true) {
        self.binding = binding
        if pendingScore == binding.wrappedValue.score { pendingScore = nil }
        // View rendering only refreshes the accessor. Lifecycle callbacks also
        // initialize the controls from the note that the new document selects.
        if synchronizeSelection { synchronizeSelectionProperties() }
    }

    static func bpmValue(from text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, (20...300).contains(value) else { return nil }
        return value
    }

    static func bpmText(for value: Double) -> String {
        value.isFinite && value == value.rounded() && (20...300).contains(value) ? String(Int(value)) : String(value)
    }

    func commit(_ candidate: GuitarScore, name: String, validate: Bool = true) {
        guard candidate != score else { return }
        if validate, let issue = ScoreValidator.validate(candidate).first(where: { $0.severity == .error }) {
            error = issue.message; return
        }
        restore(candidate, name: name)
    }

    private func restore(_ updated: GuitarScore, name: String) {
        let old = score
        let retainedPosition = displayTick
        logUndo("register " + name)
        undoManager?.registerUndo(withTarget: self) { target in target.restore(old, name: name) }
        undoManager?.setActionName(name)
        stopOwnedPlayback()
        pendingScore = updated
        binding?.wrappedValue.score = updated
        measureIndex = min(measureIndex, max(0, updated.measures.count - 1))
        tick = min(tick, updated.timeSignature.ticks - 1)
        playbackPositionTick = boundedPlaybackTick(hasEditingSelection ? absoluteTick : retainedPosition)
        loopStart = min(max(1, loopStart), updated.measures.count)
        loopEnd = min(max(loopStart, loopEnd), updated.measures.count)
        synchronizeSelectionProperties()
        if undoManager?.isUndoing == true || undoManager?.isRedoing == true { pendingDigit = nil }
        objectWillChange.send()
        logUndo("registered " + name)
    }

    func editScore(name: String, _ edit: (inout GuitarScore) -> Void) {
        var candidate = score; edit(&candidate); commit(candidate, name: name)
    }

    private func editEvents(name: String, _ edit: (inout [ScoreEvent]) -> Void) {
        guard hasEditingSelection, score.measures.indices.contains(measureIndex) else { return }
        var candidate = score
        guard let track = candidate.measures[measureIndex].voices.firstIndex(where: { $0.voice == voice }) else { return }
        edit(&candidate.measures[measureIndex].voices[track].events)
        candidate.measures[measureIndex].voices[track].events.sort { $0.startTick < $1.startTick }
        commit(candidate, name: name)
    }

    func select(measure: Int, string: Int, tick: Int) {
        guard !score.measures.isEmpty else { return }
        measureIndex = min(max(0, measure), score.measures.count - 1)
        self.string = min(max(1, string), 6)
        self.tick = min(max(0, tick), score.timeSignature.ticks - 1)
        hasEditingSelection = true
        playbackPositionTick = absoluteTick
        pendingDigit = nil
        synchronizeSelectionProperties()
        if let audio, audio.ownerID == owner {
            if audio.isPlaying { audio.pause() }
            audio.seek(to: playbackPositionTick)
        }
        keyboardFocusToken = UUID()
    }

    func clearSelection() {
        hasEditingSelection = false
        pendingDigit = nil
        keyboardFocusToken = UUID()
    }

    func selectTime(measure: Int, string: Int, approximateTick: Int, tolerance: Int) {
        guard !score.measures.isEmpty else { return }
        let index = min(max(0, measure), score.measures.count - 1)
        let position = editingTick(measure: index, approximateTick: approximateTick, tolerance: tolerance)
        select(measure: index, string: string, tick: position)
    }

    private func editingTick(measure index: Int, approximateTick: Int, tolerance: Int) -> Int {
        let events = score.measures[index].events(for: voice)
        let closest = events.min { abs($0.startTick - approximateTick) < abs($1.startTick - approximateTick) }
        if let closest, abs(closest.startTick - approximateTick) < tolerance {
            return closest.startTick
        }
        let step = rhythm.ticks
        let lastGridTick = max(0, (score.timeSignature.ticks - step) / step) * step
        let snapped = Int((Double(approximateTick) / Double(step)).rounded()) * step
        return min(lastGridTick, max(0, snapped))
    }

    /// Audio may seek between notes, while subsequent recording stays on the
    /// current rhythm grid and always leaves room for a complete event.
    @discardableResult
    func locatePlayback(at requestedTick: Int) -> Int {
        let bounded = boundedPlaybackTick(requestedTick)
        playbackPositionTick = bounded
        // Keep a legal insertion grid ready without making it an active selection.
        if !score.measures.isEmpty {
            measureIndex = bounded / score.timeSignature.ticks
            tick = editingTick(measure: measureIndex, approximateTick: bounded % score.timeSignature.ticks, tolerance: 0)
        }
        clearSelection()
        if let audio, audio.ownerID == owner { audio.seek(to: bounded) }
        return bounded
    }

    private func synchronizeSelectionProperties() {
        if let event = selectedEvent { rhythm = event.rhythm }
        if let note = selectedNote { technique = note.technique; targetFret = note.targetFret ?? note.fret }
    }

    func insertDigit(_ digit: Int) {
        guard hasEditingSelection else { return }
        let now = Date.timeIntervalSinceReferenceDate
        var fret = digit
        if let pending = pendingDigit, now - pending.time < 0.8,
           pending.measure == measureIndex, pending.voice == voice, pending.string == string, pending.tick == tick,
           pending.digit <= 2, pending.digit * 10 + digit <= 24 {
            fret = pending.digit * 10 + digit
            pendingDigit = nil
        } else {
            pendingDigit = (digit, now, measureIndex, voice, string, tick)
        }
        insertFret(fret)
    }

    func insertFret(_ fret: Int) {
        let note = GuitarNote(string: string, fret: fret, technique: technique,
                              targetFret: [.hammerOn, .pullOff, .slide].contains(technique) ? targetFret : nil)
        editEvents(name: "输入品位") { events in
            if let index = events.firstIndex(where: { $0.startTick == tick }) {
                if let n = events[index].notes.firstIndex(where: { $0.string == string }) {
                    var updated = note; updated.id = events[index].notes[n].id
                    updated.velocity = events[index].notes[n].velocity
                    updated.tieToNext = events[index].notes[n].tieToNext
                    events[index].notes[n] = updated
                } else { events[index].notes.append(note) }
            } else { events.append(ScoreEvent(startTick: tick, rhythm: rhythm, notes: [note])) }
        }
        if let inserted = selectedNote, inserted.fret == fret {
            audio?.preview(notes: [inserted], tuning: score.tuning, owner: auditionOwner)
        }
    }

    func insertRest() {
        editEvents(name: "输入休止符") { events in
            if let index = events.firstIndex(where: { $0.startTick == tick }) {
                events[index].notes = []
                events[index].rhythm = rhythm
            } else {
                events.append(ScoreEvent(startTick: tick, rhythm: rhythm, notes: []))
            }
        }
        pendingDigit = nil
    }

    func delete() {
        editEvents(name: "删除音符") { events in
            guard let index = events.firstIndex(where: { $0.startTick == tick }) else { return }
            if events[index].notes.isEmpty { events.remove(at: index) }
            else {
                events[index].notes.removeAll { $0.string == string }
                // Keep the lyric anchored to an explicit rest after its last note is removed.
                if events[index].notes.isEmpty && events[index].lyric == nil { events.remove(at: index) }
            }
        }
        pendingDigit = nil
    }

    func updateRhythm(_ value: Rhythm) {
        rhythm = value
        if selectedEvent != nil { editEvents(name: "更改时值") { events in
            if let index = events.firstIndex(where: { $0.startTick == tick }) { events[index].rhythm = value }
        } }
        rhythm = selectedEvent?.rhythm ?? value
        keyboardFocusToken = UUID()
    }

    func updateSelectedNote(_ edit: (inout GuitarNote) -> Void, name: String) {
        editEvents(name: name) { events in
            guard let event = events.firstIndex(where: { $0.startTick == tick }),
                  let note = events[event].notes.firstIndex(where: { $0.string == string }) else { return }
            edit(&events[event].notes[note])
        }
    }

    func updateLyric(_ value: String) {
        editEvents(name: "更改歌词") { events in
            guard let index = events.firstIndex(where: { $0.startTick == tick }) else { return }
            events[index].lyric = value.isEmpty ? nil : value
        }
    }

    func applyTechnique(_ value: GuitarTechnique) {
        technique = value
        if let note = selectedNote {
            if value == .hammerOn { targetFret = min(24, note.fret + 2) }
            if value == .pullOff { targetFret = max(0, note.fret - 2) }
            if value == .slide { targetFret = note.fret <= 21 ? note.fret + 3 : note.fret - 3 }
        }
        updateSelectedNote({ note in note.technique = value; note.targetFret = [.hammerOn, .pullOff, .slide].contains(value) ? targetFret : nil }, name: "更改技巧")
        technique = selectedNote?.technique ?? value
    }

    func move(horizontal: Int = 0, vertical: Int = 0) {
        guard !score.measures.isEmpty else { return }
        let nextString = min(6, max(1, string + vertical))
        var position = absoluteTick
        if !hasEditingSelection {
            // First arrow returns to editing at the current transport location.
            selectTime(measure: displayTick / score.timeSignature.ticks, string: nextString,
                       approximateTick: displayTick % score.timeSignature.ticks, tolerance: 0)
            return
        }
        if horizontal != 0 {
            let amount = selectedEvent?.rhythm.ticks ?? rhythm.ticks
            let next = absoluteTick + horizontal * amount
            if next >= 0 && next < score.totalTicks { position = next }
        }
        select(measure: position / score.timeSignature.ticks, string: nextString, tick: position % score.timeSignature.ticks)
    }

    func addMeasure() {
        editScore(name: "添加小节") { $0.measures.append(ScoreMeasure()) }
        select(measure: score.measures.count - 1, string: string, tick: 0)
        loopEnd = max(loopEnd, score.measures.count)
    }

    func deleteMeasure() {
        guard hasEditingSelection else { return }
        guard score.measures.count > 1 else { error = "曲谱至少需要一个小节。"; return }
        editScore(name: "删除小节") { $0.measures.remove(at: measureIndex) }
        tick = 0
        playbackPositionTick = absoluteTick
    }

    func copy() {
        guard let event = selectedEvent, let data = try? JSONEncoder().encode(event) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .init("com.guitarget.event"))
        NSPasteboard.general.setString(String(data: data, encoding: .utf8) ?? "", forType: .string)
    }

    func cut() {
        copy()
        editEvents(name: "剪切事件") { $0.removeAll { $0.startTick == tick } }
    }

    func paste() {
        guard hasEditingSelection else { return }
        let data = NSPasteboard.general.data(forType: .init("com.guitarget.event")) ?? NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
        guard let data, var event = try? JSONDecoder().decode(ScoreEvent.self, from: data) else {
            error = "剪贴板中没有可粘贴的六线谱事件。"; return
        }
        event.id = UUID(); event.startTick = tick
        event.notes = event.notes.map { note in var n = note; n.id = UUID(); return n }
        editEvents(name: "粘贴音符") { events in
            events.removeAll { $0.startTick == tick }; events.append(event)
        }
    }

    func applyTransportSettings() {
        guard let audio, audio.ownerID == nil || audio.ownerID == owner else { return }
        audio.loopRange = loopEnabled ? (max(0, loopStart - 1) * score.timeSignature.ticks)..<(min(score.measures.count, max(loopStart, loopEnd)) * score.timeSignature.ticks) : nil
    }

    func playPause() {
        guard let audio else { return }
        if audio.ownerID == owner, audio.isPlaying {
            audio.pause()
            playbackPositionTick = boundedPlaybackTick(audio.currentTick)
            return
        }
        guard canStartPlayback else { return }
        if audio.ownerID == owner, audio.isPaused { audio.resume() }
        else {
            // An explicit play action takes ownership before installing this
            // document's loop settings, so it cannot rebuild another score.
            audio.stop()
            applyTransportSettings()
            audio.play(score: score, owner: owner, fromTick: boundedPlaybackTick(playbackPositionTick))
        }
        if audio.ownerID == owner, audio.isPlaying { clearSelection() }
    }

    func playFrom(tick: Int) {
        guard let audio, canStartPlayback else { return }
        let position = boundedPlaybackTick(tick)
        audio.stop()
        applyTransportSettings()
        audio.play(score: score, owner: owner, fromTick: position)
        if audio.ownerID == owner, audio.isPlaying {
            playbackPositionTick = position
            clearSelection()
        }
    }

    private var canStartPlayback: Bool {
        if let issue = issues.first(where: { $0.severity == .error }) {
            error = issue.message
            return false
        }
        return true
    }

    func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(); return true
            case "v": paste(); return true
            case "x": cut(); return true
            case "z": if event.modifierFlags.contains(.shift) { performRedo() } else { performUndo() }; return true
            default: return false
            }
        }
        switch event.keyCode {
        case 123: move(horizontal: -1); return true
        case 124: move(horizontal: 1); return true
        case 125: move(vertical: 1); return true
        case 126: move(vertical: -1); return true
        case 51, 117: delete(); return true
        case 49: playPause(); return true
        case 53: clearSelection(); return true
        case 48: voice = voice == .melody ? .bass : .melody; return true
        case 36: move(horizontal: 1); return true
        default: break
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if let digit = Int(key), (0...9).contains(digit) { insertDigit(digit); return true }
        let durationKeys: [String: NoteValue] = ["w": .whole, "h": .half, "q": .quarter, "e": .eighth, "s": .sixteenth, "t": .thirtySecond]
        if let value = durationKeys[key] { updateRhythm(Rhythm(value, dotted: rhythm.dotted, triplet: value == .eighth && rhythm.triplet)); return true }
        if key == "." { updateRhythm(Rhythm(rhythm.value, dotted: !rhythm.dotted)); return true }
        if key == "r" { insertRest(); return true }
        if key == "l" { updateSelectedNote({ $0.tieToNext.toggle() }, name: "切换延音"); return true }
        return false
    }
}

extension Collection {
    fileprivate subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
