import SwiftUI
import GuitarCore
import GuitarAudio

private struct ScoreTransportCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Exercise the real output renderer with both voices muted in the QA process.
@MainActor
func runScoreTransportChecks() async throws -> [String] {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ScoreTransportCheckFailure(message: message) }
    }
    let audio = AudioService.shared
    try expect(!audio.isPlaying && !audio.isPaused && !audio.isCapturing && !audio.isStartingCapture,
               "播放状态检查需要空闲的 QA 音频服务")
    let savedSpeed = audio.speed, savedLoop = audio.loopRange
    let savedMuted = audio.mutedVoices, savedMetronome = audio.metronomeEnabled, savedCountIn = audio.countInEnabled
    defer {
        audio.stop()
        audio.speed = savedSpeed
        audio.loopRange = savedLoop
        audio.mutedVoices = savedMuted
        audio.metronomeEnabled = savedMetronome
        audio.countInEnabled = savedCountIn
    }
    audio.speed = 1
    audio.loopRange = nil
    audio.mutedVoices = Set(ScoreVoice.allCases)
    audio.metronomeEnabled = false
    audio.countInEnabled = false

    final class Store { var document = GuitarScoreDocument() }
    let store = Store()
    store.document.score.bpm = 60
    store.document.score.measures = (0..<4).map { _ in
        ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: (0..<4).map {
            ScoreEvent(startTick: $0 * 960, notes: [GuitarNote(string: 1, fret: $0)])
        }), VoiceTrack(voice: .bass)])
    }
    let editor = ScoreEditorState()
    editor.connect(Binding(get: { store.document }, set: { store.document = $0 }), undoManager: nil, audio: audio)
    var passed: [String] = []

    func waitForProgress(from tick: Int) async throws {
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(40))
            if audio.isPlaying && audio.currentTick > tick { return }
        }
        throw ScoreTransportCheckFailure(message: "真实音频 renderer 没有从 \(tick) 推进：\(audio.status)")
    }
    func select(_ tick: Int) {
        editor.select(measure: tick / 3840, string: 1, tick: tick % 3840)
    }
    for round in 0..<3 {
        let first = round * 960, second = 3840 + round * 960
        select(first)
        try expect(editor.hasEditingSelection && editor.displayTick == first, "第 \(round + 1) 轮选择 A 没有同步播放位置")
        editor.playPause()
        try expect(audio.ownerID == editor.owner && audio.isPlaying && audio.currentTick == first && !editor.hasEditingSelection,
                   "第 \(round + 1) 轮没有从 A 开始播放或未退出编辑")
        try await waitForProgress(from: first)
        editor.playPause()
        let pausedTick = audio.currentTick
        try expect(audio.isPaused && !audio.isPlaying && pausedTick > first, "第 \(round + 1) 轮暂停没有保留实际 renderer 位置")
        try await Task.sleep(for: .milliseconds(80))
        try expect(audio.currentTick == pausedTick, "暂停期间播放位置仍在推进")
        select(second)
        select(second)
        try expect(audio.isPaused && audio.currentTick == second && editor.displayTick == second && editor.hasEditingSelection,
                   "第 \(round + 1) 轮暂停后重选 B（包括重复同点）没有定位 renderer")
        editor.playPause()
        try expect(audio.isPlaying && audio.currentTick == second && !editor.hasEditingSelection,
                   "第 \(round + 1) 轮从旧暂停位置续播，未从 B 开始")
        try await waitForProgress(from: second)
        editor.playPause()
    }
    passed.append("真实音频播放：连续三轮 A→播放→暂停→重选B→播放均从新位置开始，同点重复选择有效")

    let pausedTick = audio.currentTick
    editor.playPause()
    try expect(audio.isPlaying && audio.currentTick == pausedTick && !editor.hasEditingSelection,
               "未重新选择时空格没有从原暂停位置继续")
    try await waitForProgress(from: pausedTick)
    select(960)
    try expect(audio.isPaused && !audio.isPlaying && audio.currentTick == 960 && editor.hasEditingSelection,
               "播放中选择音符没有暂停并定位")
    editor.clearSelection()
    try expect(audio.isPaused && editor.displayTick == 960 && !editor.hasEditingSelection, "取消选择改变了已设置的播放位置")
    editor.playPause()
    _ = editor.locatePlayback(at: 1501)
    try expect(audio.isPlaying && audio.currentTick == 1501 && editor.displayTick == 1501 && !editor.hasEditingSelection,
               "播放中拖滑块停止了播放、重新选中了音符或丢失精确位置")
    try await waitForProgress(from: 1501)
    editor.playFrom(tick: 1920)
    try expect(audio.isPlaying && audio.currentTick == 1920 && !editor.hasEditingSelection,
               "显式从小节播放未立即使用指定位置")
    passed.append("真实音频控制：无重选空格续播，播放中选音暂停；取消选择保留位置，滑块精确定位且继续播放")

    editor.playPause()
    let beforeAuditionTick = audio.currentTick
    editor.audition(string: 1, fret: 7)
    try expect(audio.ownerID == editor.auditionOwner && editor.displayTick == beforeAuditionTick,
               "暂停后指板试听覆盖了曲谱播放位置")
    editor.playPause()
    try expect(audio.ownerID == editor.owner && audio.isPlaying && audio.currentTick == beforeAuditionTick && !editor.hasEditingSelection,
               "暂停后试听再按空格没有从原暂停位置开始")
    passed.append("试听播放归属：暂停后试听指板不会丢失曲谱位置，空格仍从原暂停点开始")

    editor.loopEnabled = true
    editor.loopStart = 1
    editor.loopEnd = 1
    editor.applyTransportSettings()
    let otherStore = Store()
    otherStore.document = store.document
    let otherEditor = ScoreEditorState()
    otherEditor.connect(Binding(get: { otherStore.document }, set: { otherStore.document = $0 }), undoManager: nil, audio: audio)
    let originalOwnerTick = audio.currentTick
    otherEditor.select(measure: 1, string: 2, tick: 960)
    _ = otherEditor.locatePlayback(at: 5001)
    otherEditor.clearSelection()
    otherEditor.loopEnabled = true
    otherEditor.loopStart = 2
    otherEditor.loopEnd = 3
    otherEditor.applyTransportSettings()
    try expect(audio.ownerID == editor.owner && audio.isPlaying && audio.currentTick == originalOwnerTick && audio.loopRange == 0..<3840,
               "另一文档的选择、滑块、取消选择或循环设置改变了正在播放的文档")
    try expect(otherEditor.displayTick == 5001 && !otherEditor.hasEditingSelection,
               "另一文档的本地播放位置被共享音频时钟覆盖")
    otherEditor.playPause()
    try expect(audio.ownerID == otherEditor.owner && audio.isPlaying && audio.currentTick == 5001 && audio.loopRange == 3840..<11520,
               "另一文档明确点击播放后没有取得播放权或采用自己的位置与循环")
    otherEditor.stopOwnedPlayback()
    editor.loopEnabled = false
    editor.applyTransportSettings()
    passed.append("多文档音频归属：选择与循环设置不干扰正在播放的文档，明确播放才取得播放权")

    editor.stopOwnedPlayback()
    audio.countInEnabled = true
    select(2880)
    editor.playPause()
    try expect(audio.isPlaying && audio.isCountingIn && audio.currentTick == 2880 && !editor.hasEditingSelection,
               "预备拍没有保留起播位置或退出编辑")
    select(960)
    try expect(audio.isPaused && !audio.isPlaying && !audio.isCountingIn && audio.currentTick == 960 && editor.hasEditingSelection,
               "预备拍期间选音没有暂停、取消预备拍并定位")
    audio.countInEnabled = false
    editor.playPause()
    try expect(audio.isPlaying && !audio.isCountingIn && audio.currentTick == 960, "预备拍期间重选后仍从旧位置或旧预备拍继续")
    passed.append("真实预备拍：期间重新选择会暂停并取消预备拍，从新位置继续")

    select(0)
    editor.editScore(name: "检查编辑使 renderer 失效") { score in
        score.measures = Array(score.measures.prefix(1))
        score.measures[0].voices[0].events[0].notes[0].fret = 7
    }
    try expect(audio.ownerID == nil && !audio.isPlaying && !audio.isPaused && editor.hasEditingSelection,
               "修改曲谱没有清除旧 renderer/暂停会话或错误退出编辑")
    editor.playPause()
    try expect(audio.isPlaying && audio.ownerID == editor.owner, "修改曲谱后无法重新播放")
    audio.pause()
    audio.seek(to: 10000)
    try expect(audio.currentTick == store.document.score.totalTicks && audio.currentTick == 3840,
               "编辑后播放仍使用旧曲谱长度的快照")
    editor.stopOwnedPlayback()
    passed.append("真实音频快照：修改曲谱清除旧暂停会话，重新播放及定位使用新曲谱长度")

    var invalidScore = editor.score
    invalidScore.measures[0].voices[0].events[0].notes[0].fret = 25
    editor.commit(invalidScore, name: "构造不可播放曲谱", validate: false)
    select(960)
    editor.playPause()
    try expect(editor.error != nil && editor.hasEditingSelection && editor.displayTick == 960 && !audio.isPlaying && !audio.isPaused,
               "播放验证失败后丢失编辑选择、改变位置或启动了音频")
    passed.append("播放失败：无效曲谱保持编辑选择和目标位置，不创建播放会话")
    return passed
}
