import SwiftUI
import AppKit
import GuitarCore

private struct ScorePerformanceCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Exercises the document-facing performance boundary without opening any audio device.
@MainActor
func runScorePerformanceChecks() throws -> [String] {
    final class Store { var document = GuitarScoreDocument() }
    let store = Store()
    store.document.score = GuitarScore(title: "单音跟随验收", measures: (0..<2).map { _ in
        ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: [0, 3, 5, 7].enumerated().map {
            ScoreEvent(startTick: $0.offset * 960, notes: [GuitarNote(string: 1, fret: $0.element)])
        }), VoiceTrack(voice: .bass)])
    })
    let original = store.document.score
    let editor = ScoreEditorState()
    let manager = UndoManager()
    manager.groupsByEvent = false
    editor.refreshDocumentBinding(Binding(get: { store.document }, set: { store.document = $0 }))
    editor.undoManager = manager
    func change(_ body: () -> Void) {
        manager.beginUndoGrouping(); body(); manager.endUndoGrouping()
    }
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ScorePerformanceCheckFailure(message: message) }
    }
    var passed: [String] = []

    // Leave both undo and redo populated before entering performance. Guarded actions
    // must preserve actual native history, not only leave the current score unchanged.
    change { editor.editScore(name: "第一次标题") { $0.title = "第一次标题" } }
    change { editor.editScore(name: "第二次标题") { $0.title = "第二次标题" } }
    editor.performUndo()
    try expect(manager.canUndo && manager.canRedo && editor.score.title == "第一次标题", "无法构造演奏模式前的撤销与重做历史")
    editor.select(measure: 1, string: 2, tick: 960)
    let storedPlaybackTick = editor.playbackPositionTick
    editor.selectAudioSource(.reference)
    try expect(editor.audioSource == .score && editor.hasEditingSelection, "未附加音频时仍进入了原声播放")
    editor.selectAudioSource(.performance)
    try expect(editor.isPerformanceMode && !editor.canEdit && !editor.hasEditingSelection,
               "进入演奏模式未锁定改谱或清除编辑选择")
    try expect(editor.displayTick == 0 && editor.playbackPositionTick == storedPlaybackTick,
               "演奏模式继承了曲谱播放时钟或破坏了保存的曲谱播放位置")
    passed.append("演奏模式切换：清除编辑选择、锁定改谱，跟随位置与曲谱播放位置分离")

    let lockedScore = editor.score
    let lockedMeasure = editor.measureIndex, lockedTick = editor.tick, lockedString = editor.string
    let undoName = manager.undoActionName, redoName = manager.redoActionName
    var rejectedCandidate = lockedScore
    rejectedCandidate.title = "不应写入演奏模式"
    var editBodyWasCalled = false
    let actions: [(String, () -> Void)] = [
        ("直接提交", { editor.commit(rejectedCandidate, name: "禁止提交") }),
        ("文档编辑", { editor.editScore(name: "禁止编辑") { editBodyWasCalled = true; $0.title = "禁止修改" } }),
        ("品位输入", { editor.insertFret(12) }),
        ("数字输入", { editor.insertDigit(2) }),
        ("鼠标选音", { editor.select(measure: 0, string: 6, tick: 2880) }),
        ("鼠标栅格定位", { editor.selectTime(measure: 0, string: 4, approximateTick: 1900, tolerance: 100) }),
        ("播放滑块定位", { _ = editor.locatePlayback(at: 6000) }),
        ("从小节播放", { editor.playFrom(tick: 3840) }),
        ("撤销", { editor.performUndo() }),
        ("重做", { editor.performRedo() }),
        ("移动编辑位置", { editor.move(horizontal: 1, vertical: 1) }),
        ("新增小节", { editor.addMeasure() }),
        ("删除小节", { editor.deleteMeasure() }),
        ("删除音符", { editor.delete() }),
        ("输入休止符", { editor.insertRest() }),
        ("更改时值", { editor.updateRhythm(Rhythm(.eighth)) }),
        ("更改技巧", { editor.applyTechnique(.palmMute) }),
        ("更改歌词", { editor.updateLyric("不应写入的歌词") }),
        ("更改音符", { editor.updateSelectedNote({ $0.fret = 8 }, name: "禁止改音") })
    ]
    for (name, action) in actions {
        action()
        try expect(store.document.score == lockedScore && editor.score == lockedScore, "演奏模式下\(name)修改了曲谱")
        try expect(editor.measureIndex == lockedMeasure && editor.tick == lockedTick && editor.string == lockedString
                   && !editor.hasEditingSelection && editor.playbackPositionTick == storedPlaybackTick && editor.displayTick == 0,
                   "演奏模式下\(name)改变了编辑或播放位置")
        try expect(manager.canUndo && manager.canRedo && manager.undoActionName == undoName && manager.redoActionName == redoName,
                   "演奏模式下\(name)消耗或污染了撤销历史")
    }
    try expect(!editBodyWasCalled, "演奏模式仍执行了曲谱编辑闭包")
    passed.append("演奏模式操作边界：提交、改谱、鼠标定位、从小节播放及撤销重做均不改文档、位置或历史")

    let keys: [(String, UInt16, NSEvent.ModifierFlags)] = [
        ("2", 19, []), ("q", 12, []), ("r", 15, []), ("l", 37, []), (".", 47, []),
        ("\t", 48, []), ("\r", 36, []), ("", 124, []), ("", 125, []), ("", 51, []),
        ("z", 6, [.command]), ("z", 6, [.command, .shift]), ("v", 9, [.command]), ("x", 7, [.command])
    ]
    for (characters, keyCode, modifiers) in keys {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else {
            throw ScorePerformanceCheckFailure(message: "无法构造演奏键盘验收事件")
        }
        _ = editor.handleKey(event)
        try expect(editor.score == lockedScore && store.document.score == lockedScore && editor.voice == .melody
                   && editor.measureIndex == lockedMeasure && editor.tick == lockedTick && editor.string == lockedString
                   && editor.playbackPositionTick == storedPlaybackTick && !editor.hasEditingSelection
                   && manager.canUndo && manager.canRedo,
                   "演奏模式下键码 \(keyCode) 改谱、切换声部、移动位置或破坏了历史")
    }
    passed.append("演奏模式键盘：数字、时值、休止符、延音、方向键、删除和编辑快捷键均保持只读")

    func pitch(_ midi: Double, at time: Double, onset: Double?, rms: Double = 0.1) {
        editor.follower.consume(PitchObservation(timestamp: time, frequency: MusicTheory.frequency(midi: midi),
                                                 confidence: 0.99, rms: rms, onsetTimestamp: onset))
    }
    func play(_ midi: Double, at time: Double) {
        for offset in [0.0, 0.05, 0.10, 0.15] { pitch(midi, at: time + offset, onset: time) }
    }
    editor.follower.start(score: editor.score, voice: editor.voice, at: 10)
    play(64, at: 10)
    try expect(editor.displayTick == 0 && editor.follower.nextIndex == 1, "首个演奏音符没有建立跟随位置")
    play(67, at: 11)
    try expect(editor.displayTick == 960 && editor.playbackPositionTick == storedPlaybackTick,
               "第二个演奏音符未推进谱面位置，或把识别位置写入音频播放时间")
    let located = editor.locatePlayback(at: 7000)
    editor.select(measure: 1, string: 1, tick: 2880)
    editor.playFrom(tick: 7000)
    try expect(located == 960 && editor.displayTick == 960 && editor.playbackPositionTick == storedPlaybackTick,
               "已开始跟随后，鼠标定位仍覆盖了实际演奏位置")
    pitch(67, at: 20, onset: 11, rms: 0)
    play(52, at: 21)
    try expect(editor.displayTick == 960, "静音、等待或错误音高推进了演奏谱面")
    editor.follower.pause()
    play(69, at: 22)
    try expect(editor.displayTick == 960, "暂停跟随时仍移动谱面")
    editor.follower.resume(at: 30)
    play(69, at: 30)
    try expect(editor.displayTick == 1920 && editor.playbackPositionTick == storedPlaybackTick
               && editor.score == lockedScore && !editor.hasEditingSelection,
               "恢复演奏没有跟随新拨弦音符，或在跟随中改动文档和播放位置")
    passed.append("真实编辑状态接入：谱面只随确认音符推进，静音/错音/暂停和鼠标点击不推动音频时间")

    editor.selectAudioSource(.score)
    try expect(editor.canEdit && !editor.isPerformanceMode && editor.displayTick == storedPlaybackTick && !editor.follower.isRunning,
               "切回曲谱音源未恢复编辑或保存的曲谱播放位置")
    editor.performRedo()
    try expect(editor.score.title == "第二次标题", "演奏模式消耗了进入前的重做记录")
    editor.performUndo()
    try expect(editor.score == lockedScore, "演奏模式后的原生撤销未还原第一条标题记录")
    editor.performUndo()
    try expect(editor.score == original, "演奏模式丢失了更早的撤销历史")
    editor.select(measure: 0, string: 1, tick: 0)
    change { editor.insertFret(1) }
    try expect(editor.selectedNote?.fret == 1 && store.document.score != original, "切回曲谱音源后品位编辑没有恢复")
    editor.performUndo()
    try expect(editor.score == original, "恢复编辑后的新操作不能撤销")
    editor.performRedo()
    try expect(editor.selectedNote?.fret == 1, "恢复编辑后的新操作不能重做")
    passed.append("切回曲谱音源：恢复原播放位置与完整撤销重做历史，新输入仍可正常撤销重做")

    return passed
}
