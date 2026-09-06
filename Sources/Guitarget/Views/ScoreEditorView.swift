import SwiftUI
import GuitarCore
import GuitarAudio

struct ScoreEditorView: View {
    @Binding var document: GuitarScoreDocument
    @ObservedObject var audio: AudioService
    var fileURL: URL? = nil
    @EnvironmentObject private var library: ScoreLibraryStore
    @StateObject private var editor = ScoreEditorState()
    @Environment(\.undoManager) private var undoManager
    @State private var practiceVisible = false
    @State private var libraryVisible = false
    @State private var librarySelection: UUID?

    private var score: GuitarScore { document.score }
    private var ownsAudio: Bool { audio.ownerID == editor.owner }
    private var libraryEntry: LocalScoreLibraryEntry? { library.entry(for: fileURL) }
    private var transportPositionTitle: String {
        if ownsAudio && audio.isCountingIn { return "预备拍" }
        let measure = ownsAudio && (audio.isPlaying || audio.isPaused) ? audio.currentTick / score.timeSignature.ticks : editor.measureIndex
        return "第 \(measure + 1) 小节"
    }

    var body: some View {
        // Refresh the document accessor before child views read selection state.
        // This only updates the bridge; it does not publish changes while rendering.
        let _ = editor.connect($document, undoManager: undoManager, audio: audio, synchronizeSelection: false)
        return VStack(spacing: 0) {
            transport
            if let entry = libraryEntry, entry.localAudioFilename != nil || entry.appleMusicURL != nil {
                Divider()
                HStack(spacing: 16) {
                    if entry.localAudioFilename != nil {
                        ReferenceAudioControls(entry: entry, player: library.referenceAudio).frame(maxWidth: 580)
                    }
                    if entry.appleMusicURL != nil {
                        Button("在“音乐”中打开") {
                            library.openAppleMusic(entry)
                            if let error = library.error { editor.error = error; library.error = nil }
                        }
                    }
                    Spacer()
                    Text("原声独立播放").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            Divider()
            rhythmBar
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    notationScroll
                    Divider()
                    linkedFretboard
                }.frame(minWidth: 520)
                if editor.inspectorVisible {
                    ScoreInspectorView(document: $document, editor: editor, audio: audio)
                        .frame(minWidth: 230, idealWidth: 260, maxWidth: 310)
                }
            }
            Divider()
            statusBar
            AudioStatusBar(audio: audio)
        }
        .frame(minWidth: 850, minHeight: 650)
        .navigationTitle(score.title)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ScoreKeyboardResponder(focusToken: editor.keyboardFocusToken, editor: editor).frame(width: 0, height: 0))
        .onAppear { editor.connect($document, undoManager: undoManager, audio: audio) }
        .onChange(of: document.score) { _, _ in
            editor.connect($document, undoManager: undoManager, audio: audio)
            editor.objectWillChange.send()
        }
        .onDisappear { editor.stopOwnedPlayback() }
        .alert("无法完成此操作", isPresented: Binding(get: { editor.error != nil }, set: { if !$0 { editor.error = nil } })) {
            Button("好", role: .cancel) { editor.error = nil }
        } message: { Text(editor.error ?? "") }
        .sheet(isPresented: $editor.helpVisible) { keyboardHelp }
        .sheet(isPresented: $libraryVisible) { MyScoreLibraryView(selectedID: librarySelection) }
        .sheet(isPresented: $practiceVisible) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("曲谱跟练").font(.title2.bold())
                    Spacer()
                    Button("完成") { practiceVisible = false }
                }
                PracticePanel(audio: audio, score: score)
            }.padding(24).frame(minWidth: 680, minHeight: 420)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if libraryEntry == nil {
                    Button {
                        if let id = library.add(score) { librarySelection = id; libraryVisible = true }
                        else { editor.error = library.error; library.error = nil }
                    } label: { Label("存入我的曲库", systemImage: "square.and.arrow.down") }
                        .help("将当前曲谱（包括未保存修改）存为曲库中的新副本")
                }
                Button { librarySelection = libraryEntry?.id; libraryVisible = true } label: { Label("我的曲库", systemImage: "music.note.house") }
                Button { editor.stopOwnedPlayback(); practiceVisible = true } label: { Label("跟练", systemImage: "waveform.badge.mic") }
                Button { editor.addMeasure() } label: { Label("添加小节", systemImage: "plus.rectangle.on.rectangle") }.help("添加空白小节")
                Button { editor.helpVisible = true } label: { Label("键盘帮助", systemImage: "keyboard") }
                Button { editor.inspectorVisible.toggle() } label: { Label("检查器", systemImage: "sidebar.right") }
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 13) {
            HStack(spacing: 6) {
                Button { editor.playPause() } label: {
                    Image(systemName: ownsAudio && audio.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
                }.buttonStyle(.borderedProminent).help("播放 / 暂停（空格）")
                Button { editor.stopOwnedPlayback() } label: { Image(systemName: "stop.fill") }.help("停止")
                Button { editor.select(measure: 0, string: editor.string, tick: 0); if ownsAudio { audio.seek(to: 0) } } label: { Image(systemName: "backward.end.fill") }.help("回到开头")
            }
            Text(transportPositionTitle)
                .font(.system(.body, design: .monospaced)).frame(width: 90, alignment: .leading)
            Slider(value: Binding(get: { Double(ownsAudio && (audio.isPlaying || audio.isPaused) ? audio.currentTick : editor.absoluteTick) }, set: { value in
                let tick = editor.locatePlayback(at: Int(value))
                if ownsAudio { audio.seek(to: tick) }
            }), in: 0...Double(max(1, score.totalTicks - 1)))
                .help("定位播放位置")
            Picker("变速", selection: $audio.speed) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in Text(String(format: "%.2g×", speed)).tag(speed) }
            }.frame(width: 105)
            Toggle(isOn: $audio.metronomeEnabled) { Image(systemName: "metronome") }.toggleStyle(.button).help("节拍器")
            Toggle(isOn: $audio.countInEnabled) { Text("预备拍") }.toggleStyle(.button)
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var rhythmBar: some View {
        HStack(spacing: 10) {
            Picker("声部", selection: $editor.voice) {
                Text("↑ 旋律").tag(ScoreVoice.melody)
                Text("↓ 低音").tag(ScoreVoice.bass)
            }.pickerStyle(.segmented).frame(width: 160)
            Divider().frame(height: 22)
            Picker("时值", selection: Binding(get: { editor.rhythm.value }, set: { editor.updateRhythm(Rhythm($0, dotted: editor.rhythm.dotted, triplet: $0 == .eighth && editor.rhythm.triplet)) })) {
                ForEach(NoteValue.allCases) { value in Text(value.title).tag(value) }
            }.frame(width: 105)
            Toggle("附点", isOn: Binding(get: { editor.rhythm.dotted }, set: { editor.updateRhythm(Rhythm(editor.rhythm.value, dotted: $0)) })).toggleStyle(.button)
            Toggle("八分三连音", isOn: Binding(get: { editor.rhythm.triplet }, set: { editor.updateRhythm(Rhythm($0 ? .eighth : editor.rhythm.value, triplet: $0)) })).toggleStyle(.button)
            Button { editor.insertRest() } label: { Text("休止") }.help("输入休止符（R）")
            Button { editor.delete() } label: { Image(systemName: "delete.left") }.help("删除当前弦音符")
            Spacer(minLength: 0)
            Button { editor.performUndo() } label: { Image(systemName: "arrow.uturn.backward") }.help("撤销（⌘Z）")
            Button { editor.performRedo() } label: { Image(systemName: "arrow.uturn.forward") }.help("重做（⇧⌘Z）")
        }.controlSize(.small).padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var notationScroll: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(score.title).font(.system(size: 25, weight: .bold, design: .serif))
                            Text("钢弦吉他 · \(score.timeSignature.title) · ♩ = \(Int(score.bpm)) · \(score.measures.count) 小节")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("旋律 ↑").foregroundStyle(.blue)
                            Text("低音 ↓").foregroundStyle(.orange)
                        }.font(.caption)
                    }.padding(.horizontal, 5)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360 * editor.zoom), spacing: 14)], spacing: 14) {
                        ForEach(Array(score.measures.enumerated()), id: \.element.id) { index, _ in
                            VStack(spacing: 0) {
                                HStack {
                                    Text("\(index + 1)").font(.system(.caption, design: .monospaced).bold())
                                    Spacer()
                                    if editor.loopEnabled && (editor.loopStart...max(editor.loopStart, editor.loopEnd)).contains(index + 1) {
                                        Image(systemName: "repeat").foregroundStyle(.green)
                                    }
                                    if editor.measureIndex == index { Text("已选择").foregroundStyle(.secondary).font(.caption2) }
                                }.padding(.horizontal, 12).padding(.vertical, 6)
                                ScoreMeasureViewport(score: score, measureIndex: index, editor: editor,
                                                     playingTick: playingTick(in: index), mutedVoices: audio.mutedVoices)
                            }
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(editor.measureIndex == index ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.2), lineWidth: 1))
                            .id(index)
                            .contextMenu {
                                Button("从此小节播放") { editor.select(measure: index, string: editor.string, tick: 0); editor.applyTransportSettings(); audio.play(score: score, owner: editor.owner, fromTick: editor.absoluteTick) }
                                Button("设为循环开始") { editor.loopStart = index + 1; editor.loopEnd = max(editor.loopEnd, editor.loopStart); editor.loopEnabled = true; editor.applyTransportSettings() }
                                Button("设为循环结束") { editor.loopEnd = index + 1; editor.loopStart = min(editor.loopStart, editor.loopEnd); editor.loopEnabled = true; editor.applyTransportSettings() }
                            }
                        }
                    }
                    Button { editor.addMeasure() } label: { Label("添加小节", systemImage: "plus") }.frame(maxWidth: .infinity)
                }.padding(22)
            }
            .onChange(of: editor.measureIndex) { _, index in withAnimation { reader.scrollTo(index, anchor: .center) } }
            .onChange(of: audio.currentTick / max(1, score.timeSignature.ticks)) { _, index in
                if ownsAudio && audio.isPlaying { withAnimation { reader.scrollTo(index, anchor: .center) } }
            }
        }
    }

    private func playingTick(in measure: Int) -> Int? {
        guard ownsAudio, !audio.isCountingIn, audio.isPlaying || audio.isPaused,
              audio.currentTick / score.timeSignature.ticks == measure else { return nil }
        return audio.currentTick % score.timeSignature.ticks
    }

    private var soundingNotes: [GuitarNote] {
        if ownsAudio && audio.isCountingIn { return [] }
        if ownsAudio && (audio.isPlaying || audio.isPaused) {
            return editor.playbackNotes(at: audio.currentTick, mutedVoices: audio.mutedVoices)
        }
        return editor.selectedEvent?.notes ?? []
    }

    private var linkedFretboard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("联动指板").font(.caption.bold())
                Text("点击试听 · 蓝色为选中或正在发声的位置").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(editor.string) 弦 · \(editor.tick) ticks").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            }
            ScoreCompactFretboard(tuning: score.tuning, notes: soundingNotes) { string, fret in
                audio.preview(notes: [GuitarNote(string: string, fret: fret)], tuning: score.tuning, owner: editor.auditionOwner)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard").foregroundStyle(.secondary)
            Text("\(editor.voice.title) · \(editor.string) 弦 · 第 \(editor.measureIndex + 1) 小节 · \(editor.tick) ticks")
            if let issue = editor.issues.first {
                Text(issue.message).foregroundStyle(issue.severity == .error ? .red : .orange).lineLimit(1).help(issue.message)
            } else { Text("数字录品位，方向键移动，Tab 切声部").foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Text("960 ticks / ♩").foregroundStyle(.secondary)
        }.font(.caption).padding(.horizontal, 16).padding(.vertical, 7)
    }

    private var keyboardHelp: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("六线谱键盘录入").font(.title2.bold())
            Text("先点击谱面选择弦和时间位置。同一时间在不同弦录入，即组成和弦。两声部各自占用时值。")
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                GridRow { Text("0–9").bold(); Text("输入品位；0.8 秒内连续输入可录入 10–24 品") }
                GridRow { Text("← → / ↑ ↓").bold(); Text("按当前时值前后移动 / 切换弦") }
                GridRow { Text("Tab / Return").bold(); Text("切换旋律与低音 / 前进一步") }
                GridRow { Text("W H Q E S T").bold(); Text("全、二分、四分、八分、十六分、三十二分") }
                GridRow { Text(". / R / L").bold(); Text("附点 / 休止 / 当前弦音符延音线") }
                GridRow { Text("⌫ / ⌘C ⌘V").bold(); Text("删除当前弦音符 / 复制粘贴整个事件") }
                GridRow { Text("⌘Z / ⇧⌘Z").bold(); Text("撤销 / 重做") }
                GridRow { Text("空格").bold(); Text("播放 / 暂停") }
            }.font(.callout)
            Text("和弦内部分音延音：把和弦按短时值分段，选择需要持续的弦，在检查器启用“延音至下一事件”，下一事件保留同弦同品位。跨小节使用相同方式。")
                .font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("完成") { editor.helpVisible = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 630)
    }
}

/// A dense measure keeps its required engraving width. Horizontal scrolling is
/// local to the measure, so the existing grid and lyric rows remain intact.
private struct ScoreMeasureViewport: View {
    private struct ViewportSize: Equatable {
        var contentWidth: CGFloat = 0
        var viewportWidth: CGFloat = 0
    }

    let score: GuitarScore
    let measureIndex: Int
    @ObservedObject var editor: ScoreEditorState
    let playingTick: Int?
    let mutedVoices: Set<ScoreVoice>
    @State private var scrollPosition = ScrollPosition(x: 0)
    @State private var viewportSize = ViewportSize()
    private var minimumWidth: CGFloat {
        CGFloat(ScoreNotationSpacing.minimumWidth(measure: score.measures[measureIndex], capacity: score.timeSignature.ticks)) * editor.zoom
    }
    private var focusTick: Int? {
        playingTick ?? (editor.measureIndex == measureIndex ? editor.tick : nil)
    }

    var body: some View {
        ScrollView(.horizontal) {
            ScoreNotationView(score: score, measureIndex: measureIndex, editor: editor,
                              playingTick: playingTick, mutedVoices: mutedVoices)
                .containerRelativeFrame(.horizontal) { width, _ in max(width, minimumWidth) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .defaultScrollAnchor(.leading)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ViewportSize.self) { geometry in
            ViewportSize(contentWidth: geometry.contentSize.width, viewportWidth: geometry.containerSize.width)
        } action: { _, size in
            viewportSize = size
            keepFocusVisible(in: size)
        }
        .onAppear { keepFocusVisible(in: viewportSize) }
        .onChange(of: focusTick) { _, _ in keepFocusVisible(in: viewportSize) }
    }

    private func keepFocusVisible(in size: ViewportSize) {
        guard let focusTick, size.viewportWidth > 0 else { return }
        // Use an actual content offset. An ID placed in a GeometryReader overlay
        // can resolve to the entire measure, which centers its middle at tick 0.
        scrollPosition.scrollTo(x: ScoreNotationSpacing.focusOffset(
            tick: focusTick, capacity: score.timeSignature.ticks,
            contentWidth: size.contentWidth, viewportWidth: size.viewportWidth))
    }
}

private struct ScoreCompactFretboard: View {
    let tuning: [Int]
    let notes: [GuitarNote]
    let onPlay: (Int, Int) -> Void
    var body: some View {
        ScrollView(.horizontal) {
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                    Text("弦").frame(width: 22)
                    ForEach(0...24, id: \.self) { fret in Text("\(fret)").frame(width: 30) }
                }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                ForEach(1...6, id: \.self) { string in
                    HStack(spacing: 1) {
                        Text("\(string)").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 22)
                        ForEach(0...24, id: \.self) { fret in
                            let active = notes.contains { $0.string == string && $0.fret == fret }
                            Button { onPlay(string, fret) } label: {
                                ZStack {
                                    Rectangle().fill(.secondary.opacity(0.3)).frame(height: string > 3 ? 1.2 : 0.7)
                                    if active { Capsule().fill(Color.accentColor).frame(width: 25, height: 16) }
                                    if active || fret == 0 { Text("\(fret)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(active ? Color.white : Color.secondary) }
                                }.frame(width: 30, height: 17)
                            }.buttonStyle(.plain).help("\(string) 弦 \(fret) 品")
                        }
                    }
                }
            }.padding(.vertical, 3)
        }.frame(height: 133)
    }
}
