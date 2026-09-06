import SwiftUI
import AppKit
import GuitarCore

private struct EditorCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
func runScoreEditorChecks() throws -> [String] {
    final class Store { var document = GuitarScoreDocument() }
    let store = Store()
    let editor = ScoreEditorState()
    let manager = UndoManager()
    manager.groupsByEvent = false
    editor.binding = Binding(get: { store.document }, set: { store.document = $0 })
    editor.undoManager = manager
    func change(_ body: () -> Void) { manager.beginUndoGrouping(); body(); manager.endUndoGrouping() }
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw EditorCheckFailure(message: message) }
    }
    var passed: [String] = []

    editor.voice = .bass
    editor.select(measure: 0, string: 6, tick: 0)
    editor.rhythm = Rhythm(.whole)
    change { editor.insertFret(0) }
    editor.voice = .melody
    editor.rhythm = Rhythm(.eighth)
    for i in 0..<8 {
        editor.select(measure: 0, string: 1, tick: i * 480)
        change { editor.insertFret(i % 5) }
    }
    try expect(store.document.score.measures[0].events(for: .bass).first?.rhythm.ticks == 3840, "原生编辑器整小节低音失败")
    try expect(store.document.score.measures[0].events(for: .melody).count == 8, "原生编辑器八个八分旋律音录入失败")
    try expect(ScoreValidator.validate(store.document.score).filter { $0.severity == .error }.isEmpty, "指弹复调验证失败")
    passed.append("原生编辑状态：整小节低音叠加八个八分旋律音")

    let fullScore = store.document.score
    manager.undo()
    try expect(store.document.score.measures[0].events(for: .melody).count == 7, "原生 UndoManager 未撤销最后事件")
    manager.redo()
    try expect(store.document.score == fullScore, "原生 UndoManager 重做未恢复完整曲谱")
    passed.append("原生 UndoManager 撤销、重做与文档 Binding 同步")

    editor.select(measure: 0, string: 6, tick: 480)
    change { editor.insertFret(3) }
    try expect(store.document.score == fullScore && editor.error != nil, "同弦跨声部冲突未保持原曲谱")
    editor.error = nil
    editor.select(measure: 0, string: 1, tick: 3360)
    change { editor.updateRhythm(Rhythm(.quarter)) }
    try expect(store.document.score == fullScore && editor.error != nil, "超小节容量未保持原曲谱")
    passed.append("冲突与超容量编辑被拒绝，另一声部保持不变")

    editor.error = nil
    editor.select(measure: 0, string: 1, tick: 0)
    change { editor.insertDigit(1) }
    change { editor.insertDigit(2) }
    try expect(editor.selectedNote?.fret == 12, "键盘两位品位组合失败")
    passed.append("两位数字品位 12 正确组合")

    let data = try ScoreIO.encode(store.document.score)
    let reopened = try ScoreIO.decode(data)
    try expect(reopened == store.document.score, "编辑后 JSON 保存重开不相等")
    passed.append("编辑后的版本化 JSON 保存重开一致")

    let tieStore = Store()
    tieStore.document.score.measures.append(ScoreMeasure())
    let tieEditor = ScoreEditorState()
    tieEditor.binding = Binding(get: { tieStore.document }, set: { tieStore.document = $0 })
    tieEditor.select(measure: 0, string: 1, tick: 2880)
    tieEditor.insertFret(3)
    tieEditor.select(measure: 0, string: 2, tick: 2880)
    tieEditor.insertFret(2)
    tieEditor.updateSelectedNote({ $0.tieToNext = true }, name: "单弦跨小节延音")
    try expect(tieEditor.selectedNote?.tieToNext == true && tieEditor.error == nil, "延音起点先于目标输入被阻止")
    try expect(tieEditor.issues.contains { $0.severity == .warning } && !tieEditor.issues.contains { $0.severity == .error }, "未完成延音应显示警告而非硬错误")
    _ = try ScoreIO.encode(tieStore.document.score)
    tieEditor.select(measure: 1, string: 2, tick: 0)
    tieEditor.insertFret(2)
    tieEditor.select(measure: 1, string: 1, tick: 0)
    tieEditor.insertFret(5)
    try expect(tieEditor.issues.isEmpty, "跨小节延音续音输入后警告未消失")
    let scheduled = ScoreScheduler.notes(tieStore.document.score)
    let sustained = scheduled.first { $0.note.string == 2 }
    let detached = scheduled.first { $0.note.string == 1 && $0.startTick == 2880 }
    try expect(sustained?.startTick == 2880 && sustained?.endTick == 4800 && sustained?.continuationIDs.count == 1, "部分和弦延音未合并跨小节持续时间")
    try expect(detached?.endTick == 3840, "未延音的和弦音错误延长")
    passed.append("和弦单音跨小节延音：先录起点可保存，续音合并且未延音音符按时结束")

    tieEditor.voice = .bass
    tieEditor.select(measure: 1, string: 6, tick: 0)
    tieEditor.rhythm = Rhythm(.whole)
    tieEditor.insertFret(0)
    let allSounding = tieEditor.playbackNotes(at: 4000, mutedVoices: [])
    let bassOnly = tieEditor.playbackNotes(at: 4000, mutedVoices: [.melody])
    try expect(allSounding.count == 3 && allSounding.filter { $0.string == 2 }.count == 1, "联动指板跨小节延音重复或漏音")
    try expect(bassOnly.count == 1 && bassOnly[0].string == 6, "联动指板未过滤静音声部")
    passed.append("联动指板使用合并延音，并排除静音声部")

    let renderStore = Store()
    let renderEditor = ScoreEditorState()
    let firstRender = renderStore.document
    renderEditor.refreshDocumentBinding(Binding(get: { firstRender }, set: { renderStore.document = $0 }))
    renderEditor.select(measure: 0, string: 4, tick: 1920)
    renderEditor.insertDigit(1)
    renderEditor.insertDigit(2)
    try expect(renderEditor.selectedNote?.fret == 12, "旧渲染 Binding 导致连续录入读取旧值")
    try expect(renderStore.document.score.measures[0].events(for: .melody).first?.notes.first?.fret == 12, "连续录入未写入当前文档")
    let secondRender = renderStore.document
    renderEditor.refreshDocumentBinding(Binding(get: { secondRender }, set: { renderStore.document = $0 }))
    try expect(renderEditor.selectedNote?.fret == 12, "重新渲染后检查器仍读取旧曲谱")
    renderEditor.move(horizontal: 1)
    renderEditor.insertFret(5)
    try expect(renderStore.document.score.measures[0].events(for: .melody).count == 2, "渲染后的下一事件覆盖了旧事件")
    passed.append("FileDocument 渲染快照：连续录入不丢失，刷新后检查器读取当前文档")

    let openedStore = Store()
    openedStore.document.score.measures = [ScoreMeasure(voices: [
        VoiceTrack(voice: .melody, events: [ScoreEvent(startTick: 0, rhythm: Rhythm(.thirtySecond),
            notes: [GuitarNote(string: 1, fret: 12, technique: .palmMute)])]),
        VoiceTrack(voice: .bass)
    ])]
    openedStore.document.score = try ScoreIO.decode(ScoreIO.encode(openedStore.document.score))
    let openedEditor = ScoreEditorState()
    let openedBinding = Binding(get: { openedStore.document }, set: { openedStore.document = $0 })
    openedEditor.refreshDocumentBinding(openedBinding, synchronizeSelection: false)
    try expect(openedEditor.selectedNote?.fret == 12 && openedEditor.rhythm.value == .quarter,
               "渲染期间的绑定刷新应仅更新文档读取，不发布属性变更")
    openedEditor.refreshDocumentBinding(openedBinding)
    try expect(openedEditor.tick == 0 && openedEditor.rhythm.value == .thirtySecond && openedEditor.technique == .palmMute && openedEditor.targetFret == 12,
               "首次打开曲谱后工具栏与检查器未读取初始选中的 12 品 PM 32 分音符")
    passed.append("首次文档连接：初始选中的 12 品 PM 32 分音符同步到时值工具栏和技巧检查器")

    let lifecycleStore = Store()
    let lifecycleEditor = ScoreEditorState()
    lifecycleEditor.refreshDocumentBinding(Binding(get: { lifecycleStore.document }, set: { lifecycleStore.document = $0 }))
    var suppliedManager: UndoManager? = UndoManager()
    suppliedManager!.groupsByEvent = false
    lifecycleEditor.undoManager = suppliedManager
    suppliedManager!.beginUndoGrouping()
    lifecycleEditor.insertFret(7)
    suppliedManager!.endUndoGrouping()
    let managerID = ObjectIdentifier(suppliedManager!)
    suppliedManager = nil
    try expect(lifecycleEditor.undoManager?.canUndo == true, "环境临时释放 UndoManager 时丢失了历史")
    let resolved = lifecycleEditor.resolveWindowUndoManager(UndoManager())
    try expect(ObjectIdentifier(resolved) == managerID, "渲染重连替换了仍有历史的 UndoManager")
    lifecycleEditor.performUndo()
    try expect(lifecycleStore.document.score.measures[0].events(for: .melody).isEmpty, "重新连接后的原生撤销未生效")
    lifecycleEditor.performRedo()
    try expect(lifecycleStore.document.score.measures[0].events(for: .melody).first?.notes.first?.fret == 7, "重新连接后的原生重做未生效")
    resolved.beginUndoGrouping(); lifecycleEditor.updateRhythm(Rhythm(.eighth)); resolved.endUndoGrouping()
    resolved.beginUndoGrouping(); lifecycleEditor.applyTechnique(.vibrato); resolved.endUndoGrouping()
    lifecycleEditor.performUndo()
    try expect(lifecycleEditor.technique == .none, "撤销技巧后检查器仍显示旧技巧")
    lifecycleEditor.performUndo()
    try expect(lifecycleEditor.rhythm.value == .quarter, "撤销时值后工具栏仍显示旧时值")
    resolved.beginUndoGrouping(); lifecycleEditor.insertDigit(1); resolved.endUndoGrouping()
    lifecycleEditor.performUndo()
    resolved.beginUndoGrouping(); lifecycleEditor.insertDigit(2); resolved.endUndoGrouping()
    try expect(lifecycleEditor.selectedNote?.fret == 2, "撤销后仍与已取消数字拼接为两位品位")
    passed.append("UndoManager 生命周期：环境释放后历史保留，重连、属性同步和撤销后录入正确")

    let textStore = Store()
    let textEditor = ScoreEditorState()
    textEditor.refreshDocumentBinding(Binding(get: { textStore.document }, set: { textStore.document = $0 }))
    let textManager = textEditor.resolveWindowUndoManager(UndoManager())
    textManager.groupsByEvent = false
    func textChange(_ body: () -> Void) { textManager.beginUndoGrouping(); body(); textManager.endUndoGrouping() }
    textChange { textEditor.insertDigit(1) }
    textChange { textEditor.insertDigit(2) }
    let titleField = ScoreTextControl(frame: .zero)
    let titleCell = ScoreTextCell(textCell: "")
    titleCell.allowsUndo = false
    titleField.cell = titleCell
    titleField.scoreEditor = textEditor
    titleField.modelText = { textEditor.score.title }
    titleField.acceptText = { value in textEditor.editScore(name: "更改标题") { $0.title = value }; return true }
    titleField.synchronizeText()
    guard let titleResponder = titleCell.fieldEditor(for: titleField) as? ScoreTextUndoView else {
        throw EditorCheckFailure(message: "曲谱文本控件没有专用的原生字段编辑器")
    }
    try expect(titleResponder.undoManager == nil && !titleResponder.allowsUndo && !titleCell.allowsUndo,
               "标题字段向 NSTextStorage 暴露了曲谱 UndoManager，可能混入字符范围 inverse")
    let textCoordinator = ScoreTextField.Coordinator()
    titleField.stringValue = "原生标题验收"
    textChange { textCoordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: titleField)) }
    try expect(textEditor.score.title == "原生标题验收" && textEditor.selectedNote?.fret == 12, "原生标题输入未实时写入曲谱")
    let undoItem = NSMenuItem(title: "撤销", action: #selector(ScoreTextUndoView.undo(_:)), keyEquivalent: "z")
    try expect(titleResponder.validateMenuItem(undoItem), "标题字段中的原生撤销菜单不可用")
    titleResponder.undo(nil)
    try expect(textEditor.score.title == "未命名曲谱" && titleField.stringValue == "未命名曲谱" && textEditor.selectedNote?.fret == 12,
               "标题字段撤销没有恢复标题或错误撤销了音符")
    let textCanvas = ScoreKeyView()
    textCanvas.editor = textEditor
    textCanvas.undo(nil)
    try expect(textEditor.selectedNote?.fret == 1 && textEditor.score.title == "未命名曲谱",
               "从标题切回谱面后撤销重新写回了已撤销标题，而非回到 1 品")
    textCanvas.redo(nil)
    titleResponder.redo(nil)
    try expect(textEditor.selectedNote?.fret == 12 && textEditor.score.title == "原生标题验收" && titleField.stringValue == "原生标题验收",
               "跨字段和谱面重做没有按顺序恢复音符及标题")
    passed.append("标题与谱面共用撤销：12品→改标题→字段撤销→Canvas撤销得到1品；跨焦点重做正确")

    let storageStore = Store()
    let storageEditor = ScoreEditorState()
    storageEditor.refreshDocumentBinding(Binding(get: { storageStore.document }, set: { storageStore.document = $0 }))
    let storageManager = storageEditor.resolveWindowUndoManager(nil)
    storageManager.groupsByEvent = false
    let storageField = ScoreTextControl(frame: NSRect(x: 0, y: 0, width: 230, height: 24))
    let storageCell = ScoreTextCell(textCell: "")
    storageField.cell = storageCell
    storageField.scoreEditor = storageEditor
    storageField.modelText = { storageEditor.score.title }
    storageField.acceptText = { value in storageEditor.editScore(name: "更改标题") { $0.title = value }; return true }
    let storageResponder = storageCell.fieldEditor(for: storageField) as! ScoreTextUndoView
    storageResponder.string = "未命名曲谱"
    // Exercise real NSTextStorage replacements, including the case where AppKit
    // re-enables text undo. None may create a score history entry or empty group.
    storageResponder.allowsUndo = true
    storageResponder.insertText("长标题原生文本替换验收", replacementRange: NSRange(location: 0, length: (storageResponder.string as NSString).length))
    try expect(storageResponder.string == "长标题原生文本替换验收" && !storageManager.canUndo && !storageManager.canRedo && storageManager.groupingLevel == 0,
               "原生 NSTextStorage 插入污染了曲谱撤销栈或创建了空组")
    storageManager.beginUndoGrouping(); _ = storageField.commitText(storageResponder.string, hasMarkedText: false); storageManager.endUndoGrouping()
    storageResponder.undo(nil)
    try expect(storageEditor.score.title == "未命名曲谱" && storageManager.canRedo, "隔离原生字符 inverse 后字段 Undo 未调用曲谱历史")
    // The native field's contents may become shorter before a score Redo. This
    // used to leave NSUndoReplaceCharacters with an out-of-range substring.
    storageResponder.string = "短"
    storageResponder.insertText("短", replacementRange: NSRange(location: 0, length: 1))
    try expect(!storageManager.canUndo && storageManager.canRedo && storageManager.groupingLevel == 0,
               "字段原生文本替换清除了曲谱 redo 或登记了字符 inverse")
    let storageRedoItem = NSMenuItem(title: "重做", action: #selector(ScoreTextUndoView.redo(_:)), keyEquivalent: "z")
    try expect(storageResponder.validateMenuItem(storageRedoItem), "隔离 NSTextStorage 后原生重做菜单不可用")
    storageResponder.redo(nil)
    try expect(storageEditor.score.title == "长标题原生文本替换验收" && !storageManager.canRedo && !storageManager.isUndoing && !storageManager.isRedoing && storageManager.groupingLevel == 0,
               "不同长度原生字段文本后的曲谱 Redo 未恢复标题或 UndoManager 状态损坏")
    passed.append("NSTextStorage 隔离：真实字符替换不登记曲谱 inverse/空组，短字段内容后菜单重做仍恢复完整标题")

    let beforeComposition = textEditor.score
    let beforeMarkedHistory = (undo: textManager.canUndo, redo: textManager.canRedo, action: textManager.undoActionName)
    // Rejected/uncommitted input must not open artificial undo groups. Foundation
    // retains even an empty explicit group, which would consume a later Undo.
    _ = titleField.commitText("中文组合输入中", hasMarkedText: true)
    try expect(textEditor.score == beforeComposition && textManager.canUndo == beforeMarkedHistory.undo && textManager.canRedo == beforeMarkedHistory.redo && textManager.undoActionName == beforeMarkedHistory.action,
               "输入法尚未提交的 marked text 被写入曲谱或改动了撤销历史")
    textChange { _ = titleField.commitText("已提交中文标题", hasMarkedText: false) }
    titleResponder.undo(nil)
    try expect(textEditor.score == beforeComposition, "中文组合输入提交后不能作为一个曲谱操作撤销")
    let bpmField = ScoreTextControl(frame: .zero)
    bpmField.scoreEditor = textEditor
    bpmField.modelText = { ScoreEditorState.bpmText(for: textEditor.score.bpm) }
    bpmField.acceptText = { value in
        guard let bpm = ScoreEditorState.bpmValue(from: value) else { return false }
        textEditor.editScore(name: "更改速度") { $0.bpm = bpm }
        return true
    }
    for incomplete in ["", "8", "-", "80..", "NaN", "inf", "301"] {
        let beforeInvalidHistory = (undo: textManager.canUndo, redo: textManager.canRedo, action: textManager.undoActionName)
        let accepted = bpmField.commitText(incomplete, hasMarkedText: false)
        try expect(!accepted && textEditor.score == beforeComposition && textManager.canUndo == beforeInvalidHistory.undo && textManager.canRedo == beforeInvalidHistory.redo && textManager.undoActionName == beforeInvalidHistory.action,
                   "BPM 未完成或非法输入被写入曲谱或改动了撤销历史：\(incomplete)")
    }
    textChange { _ = bpmField.commitText("80.125", hasMarkedText: false) }
    try expect(textEditor.score.bpm == 80.125 && ScoreEditorState.bpmValue(from: ScoreEditorState.bpmText(for: textEditor.score.bpm)) == 80.125,
               "BPM 文本格式导致合法小数速度精度丢失")
    bpmField.stringValue = "-"
    textCoordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: bpmField))
    try expect(bpmField.stringValue == "80.125" && textEditor.score.bpm == 80.125, "非法 BPM 失焦没有恢复最近合法值")
    textCanvas.undo(nil)
    let ordinaryField = NSTextField(frame: .zero)
    try expect(ordinaryField.cell?.fieldEditor(for: ordinaryField) == nil, "曲谱局部字段编辑器污染了普通文本控件")
    passed.append("原生文本输入：marked text 等待提交，非法/未完成BPM不入谱，合法小数不丢精度，普通字段保持独立")

    for draft in ["999", "-", ""] {
        let draftStore = Store()
        let draftEditor = ScoreEditorState()
        draftEditor.refreshDocumentBinding(Binding(get: { draftStore.document }, set: { draftStore.document = $0 }))
        let draftManager = draftEditor.resolveWindowUndoManager(nil)
        draftManager.groupsByEvent = false
        draftManager.beginUndoGrouping(); draftEditor.insertFret(1); draftManager.endUndoGrouping()
        let recordedScore = draftEditor.score
        let draftField = ScoreTextControl(frame: .zero)
        let draftCell = ScoreTextCell(textCell: "")
        draftField.cell = draftCell
        draftField.scoreEditor = draftEditor
        draftField.modelText = { ScoreEditorState.bpmText(for: draftEditor.score.bpm) }
        draftField.acceptText = { value in
            guard let bpm = ScoreEditorState.bpmValue(from: value) else { return false }
            draftEditor.editScore(name: "更改速度") { $0.bpm = bpm }
            return true
        }
        let draftResponder = draftCell.fieldEditor(for: draftField) as! ScoreTextUndoView
        draftField.synchronizeText()
        draftField.stringValue = draft
        textCoordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: draftField))
        try expect(draftField.hasUnacceptedDraft && draftEditor.score == recordedScore, "非法 BPM 草稿未被识别或提前入谱")
        draftResponder.undo(nil)
        try expect(draftField.stringValue == "80" && !draftField.hasUnacceptedDraft && draftEditor.score == recordedScore && draftManager.canUndo,
                   "非法 BPM 草稿的首次撤销误撤了前一音符：\(draft)")
        draftResponder.undo(nil)
        try expect(draftEditor.selectedNote == nil && draftManager.canRedo, "清除草稿后的再次撤销未继续撤销前一音符")
        let emptyScore = draftEditor.score
        draftField.stringValue = draft
        textCoordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: draftField))
        let draftUndoItem = NSMenuItem(title: "撤销", action: #selector(ScoreTextUndoView.undo(_:)), keyEquivalent: "z")
        try expect(draftResponder.validateMenuItem(draftUndoItem), "无可撤销曲谱操作时，非法草稿的撤销菜单应仍可用")
        draftResponder.redo(nil)
        try expect(draftField.stringValue == "80" && draftEditor.score == emptyScore && draftManager.canRedo,
                   "非法 BPM 草稿的首次重做消费了前一音符重做记录")
        draftResponder.redo(nil)
        try expect(draftEditor.score == recordedScore, "清除草稿后的再次重做未恢复前一音符")
    }
    passed.append("非法 BPM 草稿：首次撤销/重做仅恢复合法显示，第二次才处理音符历史，菜单在空历史时仍可清除草稿")

    let lyricField = ScoreTextControl(frame: .zero)
    let lyricCell = ScoreTextCell(textCell: "")
    lyricField.cell = lyricCell
    lyricField.scoreEditor = textEditor
    lyricField.modelText = { textEditor.selectedEvent?.lyric ?? "" }
    lyricField.acceptText = { value in textEditor.updateLyric(value); return true }
    let lyricResponder = lyricCell.fieldEditor(for: lyricField) as! ScoreTextUndoView
    textChange { _ = lyricField.commitText("一 起 sing", hasMarkedText: false) }
    lyricResponder.undo(nil)
    textCanvas.undo(nil)
    try expect(textEditor.selectedEvent?.lyric == nil && textEditor.score.title == "未命名曲谱" && textEditor.selectedNote?.fret == 12,
               "歌词字段撤销后切换谱面重复写回歌词，或破坏前一标题操作")
    textCanvas.redo(nil)
    lyricResponder.redo(nil)
    try expect(textEditor.selectedEvent?.lyric == "一 起 sing" && textEditor.score.title == "原生标题验收", "歌词与标题跨字段重做顺序错误")
    passed.append("歌词字段与曲谱共用撤销：失焦后继续撤销前一标题操作，重做依次恢复标题和歌词")

    let lyricStore = Store()
    let lyricEditor = ScoreEditorState()
    lyricEditor.binding = Binding(get: { lyricStore.document }, set: { lyricStore.document = $0 })
    let lyricManager = lyricEditor.resolveWindowUndoManager(nil)
    lyricManager.groupsByEvent = false
    func lyricChange(_ body: () -> Void) { lyricManager.beginUndoGrouping(); body(); lyricManager.endUndoGrouping() }
    lyricChange { lyricEditor.insertFret(3) }
    lyricChange { lyricEditor.updateLyric("一 起 sing") }
    try expect(lyricEditor.selectedEvent?.lyric == "一 起 sing", "歌词编辑未写入所选事件")
    lyricEditor.performUndo()
    try expect(lyricEditor.selectedEvent?.lyric == nil, "歌词撤销未恢复空值")
    lyricEditor.performRedo()
    try expect(lyricEditor.selectedEvent?.lyric == "一 起 sing", "歌词重做未恢复文本")

    // Preserve every available pasteboard representation while exercising the real commands.
    let previousClipboard: [NSPasteboardItem] = NSPasteboard.general.pasteboardItems?.map { item -> NSPasteboardItem in
        let copy = NSPasteboardItem()
        for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
        return copy
    } ?? []
    defer {
        NSPasteboard.general.clearContents()
        if !previousClipboard.isEmpty { _ = NSPasteboard.general.writeObjects(previousClipboard) }
    }
    let copiedEvent = lyricEditor.selectedEvent!
    lyricEditor.copy()
    lyricEditor.select(measure: 0, string: 1, tick: 960)
    lyricChange { lyricEditor.paste() }
    try expect(lyricEditor.selectedEvent?.lyric == copiedEvent.lyric && lyricEditor.selectedEvent?.id != copiedEvent.id,
               "事件复制粘贴丢失歌词或重复使用事件 ID")
    try expect(lyricEditor.selectedNote?.id != copiedEvent.notes.first?.id, "粘贴没有更新音符 ID")
    lyricChange { lyricEditor.updateRhythm(Rhythm(.eighth)) }
    lyricChange { lyricEditor.insertRest() }
    try expect(lyricEditor.selectedEvent?.lyric == copiedEvent.lyric && lyricEditor.selectedEvent?.notes.isEmpty == true,
               "改变时值或转为休止丢失歌词")
    lyricChange { lyricEditor.insertFret(5) }
    lyricChange { lyricEditor.delete() }
    try expect(lyricEditor.selectedEvent?.lyric == copiedEvent.lyric && lyricEditor.selectedEvent?.notes.isEmpty == true,
               "删除最后音符时应保留带歌词休止")
    lyricChange { lyricEditor.updateLyric("") }
    try expect(lyricEditor.selectedEvent?.lyric == nil, "清空歌词未移除可选字段")
    let reopenedLyrics = try ScoreIO.decode(ScoreIO.encode(lyricStore.document.score))
    try expect(reopenedLyrics == lyricStore.document.score, "带歌词曲谱保存重开不相等")
    passed.append("歌词：编辑撤销重做、复制粘贴、时值与休止转换、删音保留及保存重开")

    let voiceStore = Store()
    voiceStore.document.score.measures = [ScoreMeasure(voices: [
        VoiceTrack(voice: .melody, events: [ScoreEvent(startTick: 0, rhythm: Rhythm(.eighth), notes: [GuitarNote(string: 1, fret: 3)])]),
        VoiceTrack(voice: .bass, events: [ScoreEvent(startTick: 0, rhythm: Rhythm(.whole), notes: [GuitarNote(string: 6, fret: 0, technique: .palmMute)])])
    ])]
    let voiceEditor = ScoreEditorState()
    voiceEditor.refreshDocumentBinding(Binding(get: { voiceStore.document }, set: { voiceStore.document = $0 }))
    voiceEditor.select(measure: 0, string: 6, tick: 0)
    try expect(voiceEditor.rhythm.value == .eighth, "旋律事件时值读取失败")
    voiceEditor.voice = .bass
    try expect(voiceEditor.rhythm.value == .whole && voiceEditor.technique == .palmMute, "切换声部后未同步所选低音的时值与技巧")
    passed.append("切换声部：已有整音低音同步时值及闷音技巧")

    let entryRhythms = [Rhythm(.quarter), Rhythm(.eighth, dotted: true), Rhythm(.eighth, triplet: true), Rhythm(.thirtySecond)]
    for signature in TimeSignature.supported {
        for rhythm in entryRhythms {
            let locationStore = Store()
            locationStore.document.score.timeSignature = signature
            locationStore.document.score.measures.append(ScoreMeasure())
            let locationEditor = ScoreEditorState()
            locationEditor.refreshDocumentBinding(Binding(get: { locationStore.document }, set: { locationStore.document = $0 }))
            locationEditor.rhythm = rhythm
            let audioTick = locationEditor.locatePlayback(at: locationStore.document.score.totalTicks - 1)
            try expect(audioTick == locationStore.document.score.totalTicks - 1, "滑块丢失精确音频定位")
            try expect(locationEditor.measureIndex == 1 && locationEditor.tick % rhythm.ticks == 0 && locationEditor.tick + rhythm.ticks <= signature.ticks,
                       "\(signature.title) 小节末尾录入光标未落在能容纳当前时值的网格")
            locationEditor.insertFret(12)
            try expect(locationEditor.error == nil && locationEditor.selectedNote?.fret == 12, "小节末尾定位后无法录入完整音符")
            try expect(locationStore.document.score.measures[0].events(for: .melody).isEmpty, "末尾定位修改了另一小节")
        }
    }
    passed.append("滑块末尾定位：保留音频 tick，四种拍号的附点/三连音/32分录入均在合法网格")

    let denseEvents = (0..<32).map { ScoreEvent(startTick: $0 * 120, rhythm: Rhythm(.thirtySecond), notes: [GuitarNote(string: 1, fret: 12)]) }
    let denseMeasure = ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: denseEvents), VoiceTrack(voice: .bass)])
    let denseWidth = ScoreNotationSpacing.minimumWidth(measure: denseMeasure, capacity: 3840)
    let denseSeparation = (denseWidth - 60) / 32
    try expect(denseSeparation >= 36, "32分音符数字框和最外侧符尾仍会相交")
    let markedEvents = denseEvents.map { event in
        var copy = event
        copy.notes[0].technique = .hammerOn; copy.notes[0].targetFret = 24
        return copy
    }
    let markedWidth = ScoreNotationSpacing.minimumWidth(measure: ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: markedEvents), VoiceTrack(voice: .bass)]), capacity: 3840)
    let actualMarkWidth = ("H24" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium)]).width
    try expect(markedWidth > denseWidth && (markedWidth - 60) / 32 > 20 + actualMarkWidth / 2 + 12,
               "技巧标记没有推动小节扩宽或仍与后一音符相交")
    try expect(ScoreNotationSpacing.minimumWidth(measure: ScoreMeasure(), capacity: 3840) == 360, "空小节被无谓扩宽")
    passed.append("密集谱间距：32个两位品位及H24技巧标记有独立占宽，空小节保持紧凑")

    for width in [CGFloat(denseWidth), CGFloat(markedWidth)] {
        for viewport: CGFloat in [360, 720] {
            try expect(ScoreNotationSpacing.focusOffset(tick: 0, capacity: 3840, contentWidth: width, viewportWidth: viewport) == 0,
                       "密集谱初始选择没有从首小节左端显示")
            for event in markedEvents {
                let offset = ScoreNotationSpacing.focusOffset(tick: event.startTick, capacity: 3840, contentWidth: width, viewportWidth: viewport)
                let glyphX = 38 + CGFloat(event.startTick) / 3840 * (width - 60) - offset
                try expect(glyphX - 12 >= 0 && glyphX + 34 <= viewport,
                           "密集谱选择滚动未完整显示 \(event.startTick) ticks 的音符与技巧")
            }
        }
    }
    try expect(ScoreNotationSpacing.focusOffset(tick: 1920, capacity: 3840, contentWidth: 360, viewportWidth: 720) == 0,
               "完整可见的紧凑小节不应产生横向偏移")
    passed.append("密集谱定位：起始偏移为零，逐音与末音定位保留完整品位和技巧，紧凑谱不横移")
    return passed
}

/// Model the delayed bookkeeping of a native document without opening a window.
/// The real DocumentGroup path is separately checked by interacting with the app.
@MainActor
func runScoreEditorDelayedUndoCheck() async throws -> String {
    final class Store { var document = GuitarScoreDocument() }
    let store = Store()
    let editor = ScoreEditorState()
    let windowManager = UndoManager()
    windowManager.groupsByEvent = false
    let scoreManager = editor.resolveWindowUndoManager(windowManager)
    scoreManager.groupsByEvent = false
    guard scoreManager !== windowManager else { throw EditorCheckFailure(message: "曲谱撤销错误地采用了文档窗口的异步记账管理器") }
    editor.refreshDocumentBinding(Binding(get: { store.document }, set: { value in
        let previous = store.document
        store.document = value
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            windowManager.beginUndoGrouping()
            windowManager.registerUndo(withTarget: store) { target in target.document = previous }
            windowManager.endUndoGrouping()
        }
    }))
    scoreManager.beginUndoGrouping(); editor.insertFret(1); scoreManager.endUndoGrouping()
    try await Task.sleep(for: .milliseconds(35))
    scoreManager.beginUndoGrouping(); editor.insertFret(12); scoreManager.endUndoGrouping()
    try await Task.sleep(for: .milliseconds(35))
    editor.performUndo()
    try await Task.sleep(for: .milliseconds(35))
    guard editor.selectedNote?.fret == 1, scoreManager.canRedo else {
        throw EditorCheckFailure(message: "文档延迟记账清除了曲谱重做历史")
    }
    editor.performRedo()
    try await Task.sleep(for: .milliseconds(35))
    guard store.document.score.measures[0].events(for: .melody).first?.notes.first?.fret == 12 else {
        throw EditorCheckFailure(message: "延迟记账后的曲谱重做没有恢复 12 品")
    }
    let titleField = ScoreTextControl(frame: .zero)
    let titleCell = ScoreTextCell(textCell: "")
    titleField.cell = titleCell
    titleField.scoreEditor = editor
    titleField.modelText = { editor.score.title }
    titleField.acceptText = { value in editor.editScore(name: "更改标题") { $0.title = value }; return true }
    let titleResponder = titleCell.fieldEditor(for: titleField) as! ScoreTextUndoView
    scoreManager.beginUndoGrouping(); _ = titleField.commitText("延迟标题验收", hasMarkedText: false); scoreManager.endUndoGrouping()
    try await Task.sleep(for: .milliseconds(35))
    titleResponder.undo(nil)
    try await Task.sleep(for: .milliseconds(35))
    editor.performUndo()
    try await Task.sleep(for: .milliseconds(35))
    guard editor.score.title == "未命名曲谱", editor.selectedNote?.fret == 1 else {
        throw EditorCheckFailure(message: "异步文档记账后，从标题字段切回曲谱撤销写回了旧标题或丢失前一录谱历史")
    }
    editor.performRedo()
    try await Task.sleep(for: .milliseconds(35))
    titleResponder.redo(nil)
    try await Task.sleep(for: .milliseconds(35))
    guard editor.score.title == "延迟标题验收", editor.selectedNote?.fret == 12 else {
        throw EditorCheckFailure(message: "异步文档记账后，标题与音符跨焦点重做顺序错误")
    }
    return "异步文档记账：音符及标题共用曲谱历史，跨焦点撤销重做在延迟写入后仍正确"
}
