import SwiftUI
import GuitarCore
import GuitarAudio

struct ScoreInspectorView: View {
    @Binding var document: GuitarScoreDocument
    @ObservedObject var editor: ScoreEditorState
    @ObservedObject var audio: AudioService
    private var score: GuitarScore { document.score }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                scoreProperties
                Divider()
                noteProperties
                Divider()
                lyricProperties
                Divider()
                playbackProperties
                Divider()
                measureProperties
                if !editor.issues.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("曲谱检查").font(.headline)
                        ForEach(Array(editor.issues.prefix(8).enumerated()), id: \.offset) { _, issue in
                            Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.circle" : "info.circle")
                                .font(.caption).foregroundStyle(issue.severity == .error ? .red : .orange)
                        }
                    }
                }
            }.padding(16)
        }
        .background(.quaternary.opacity(0.25))
    }

    private var scoreProperties: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("曲谱").font(.headline)
            ScoreTextField(placeholder: "标题", text: Binding(get: { editor.score.title }, set: { value in editor.editScore(name: "更改标题") { $0.title = value } }), editor: editor)
            Picker("拍号", selection: Binding(get: { score.timeSignature }, set: { value in editor.editScore(name: "更改拍号") { $0.timeSignature = value } })) {
                ForEach(TimeSignature.supported, id: \.self) { signature in Text(signature.title).tag(signature) }
            }
            HStack {
                Text("速度")
                ScoreTextField(placeholder: "BPM", text: Binding(get: { ScoreEditorState.bpmText(for: editor.score.bpm) }, set: { value in
                    if let bpm = ScoreEditorState.bpmValue(from: value) { editor.editScore(name: "更改速度") { $0.bpm = bpm } }
                }), editor: editor, acceptsText: { ScoreEditorState.bpmValue(from: $0) != nil }, validationMessage: "速度必须是 20–300 之间的数值。")
                    .frame(width: 62)
                Text("BPM").font(.caption).foregroundStyle(.secondary)
                Stepper("速度", value: Binding(get: { score.bpm }, set: { value in editor.editScore(name: "更改速度") { $0.bpm = value } }), in: 20...300, step: 1).labelsHidden()
            }
            DisclosureGroup("调弦（MIDI，1 弦 → 6 弦）") {
                VStack(spacing: 5) {
                    ForEach(0..<6) { index in
                        HStack {
                            Text("\(index + 1) 弦").font(.caption)
                            Stepper(value: Binding(get: { score.tuning[index] }, set: { midi in editor.editScore(name: "更改调弦") { $0.tuning[index] = midi } }), in: 28...88) {
                                Text(midiName(score.tuning[index])).font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                    Button("恢复标准调弦") { editor.editScore(name: "标准调弦") { $0.tuning = [64,59,55,50,45,40] } }
                }.padding(.top, 7)
            }.font(.caption)
        }
    }

    private var noteProperties: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("当前音符").font(.headline)
            HStack {
                Text(editor.voice.title).foregroundStyle(editor.voice == .melody ? .blue : .orange)
                Spacer()
                Text("\(editor.string) 弦 · \(editor.tick) ticks").foregroundStyle(.secondary)
            }.font(.caption)
            if let note = editor.selectedNote {
                HStack {
                    Text(midiName(score.midi(for: note))).font(.title2.bold())
                    Spacer()
                    Stepper("\(note.fret) 品", value: Binding(get: { editor.selectedNote?.fret ?? 0 }, set: { value in editor.updateSelectedNote({ $0.fret = value }, name: "更改品位") }), in: 0...24)
                }
                Toggle("延音至下一事件", isOn: Binding(get: { editor.selectedNote?.tieToNext ?? false }, set: { value in editor.updateSelectedNote({ $0.tieToNext = value }, name: "更改延音") }))
                    .font(.callout)
                HStack {
                    Text("力度").font(.caption)
                    Slider(value: Binding(get: { editor.selectedNote?.velocity ?? 0.75 }, set: { value in editor.updateSelectedNote({ $0.velocity = value }, name: "更改力度") }), in: 0.05...1)
                }
            } else {
                Text(editor.selectedEvent?.notes.isEmpty == true ? "休止符" : "空位置：数字键输入 0–24 品")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Picker("技巧", selection: Binding(get: { editor.technique }, set: editor.applyTechnique)) {
                ForEach(GuitarTechnique.allCases) { technique in Text(technique.title).tag(technique) }
            }
            if [.hammerOn, .pullOff, .slide].contains(editor.technique) {
                Stepper("目标品位 \(editor.targetFret)", value: Binding(get: { editor.targetFret }, set: { value in
                    editor.targetFret = value
                    editor.updateSelectedNote({ $0.targetFret = value }, name: "更改技巧目标")
                }), in: 0...24)
                Text("技巧从当前品位连续变化至目标品位。延音线连接相邻的同弦同品位音符。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("复制事件") { editor.copy() }
                Button("粘贴事件") { editor.paste() }
            }.controlSize(.small)
        }
    }

    private var lyricProperties: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("歌词").font(.headline)
            ScoreTextField(placeholder: "输入此音的歌词或音节", text: Binding(
                get: { editor.selectedEvent?.lyric ?? "" },
                set: editor.updateLyric
            ), editor: editor, maximumLines: 4)
                .disabled(editor.selectedEvent == nil)
                .accessibilityLabel("当前事件歌词")
            Text(editor.selectedEvent == nil ? "先在谱面选中音符或休止符，再输入歌词。" : "歌词跟随当前声部的这一音，显示在谱面下方。可逐音输入，留空即可移除。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var playbackProperties: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("播放与循环").font(.headline)
            Toggle("循环选定小节", isOn: $editor.loopEnabled).onChange(of: editor.loopEnabled) { _, _ in editor.applyTransportSettings() }
            HStack {
                Picker("从", selection: $editor.loopStart) {
                    ForEach(1...score.measures.count, id: \.self) { n in Text("\(n)").tag(n) }
                }
                Picker("至", selection: $editor.loopEnd) {
                    ForEach(1...score.measures.count, id: \.self) { n in Text("\(n)").tag(n) }
                }
            }.onChange(of: editor.loopStart) { _, value in editor.loopEnd = max(value, editor.loopEnd); editor.applyTransportSettings() }
                .onChange(of: editor.loopEnd) { _, value in editor.loopStart = min(value, editor.loopStart); editor.applyTransportSettings() }
            ForEach(ScoreVoice.allCases) { voice in
                Toggle("静音\(voice.title)", isOn: Binding(get: { audio.mutedVoices.contains(voice) }, set: { mute in
                    if mute { audio.mutedVoices.insert(voice) } else { audio.mutedVoices.remove(voice) }
                }))
            }
            Text("变速保持音高。两个声部由同一个音频时钟驱动。学习模块或其他文档开始播放时会接管音频。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var measureProperties: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("第 \(editor.measureIndex + 1) 小节").font(.headline)
            ForEach(ScoreVoice.allCases) { voice in
                let events = score.measures[editor.measureIndex].events(for: voice)
                let end = events.map(\.endTick).max() ?? 0
                HStack {
                    Text(voice.title)
                    Spacer()
                    Text("\(end) / \(score.timeSignature.ticks)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }.font(.caption)
            }
            HStack {
                Button("添加小节") { editor.addMeasure() }
                Button("删除小节", role: .destructive) { editor.deleteMeasure() }
            }.controlSize(.small)
            HStack {
                Text("谱面缩放").font(.caption)
                Slider(value: $editor.zoom, in: 1...1.8)
            }
            Text("蓝色符干向上为旋律，橙色符干向下为低音。浅色休止符表示未录入的空余时值；同弦持续音冲突会阻止编辑并说明原因。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func midiName(_ midi: Int) -> String {
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        return "\(names[(midi % 12 + 12) % 12])\(midi / 12 - 1)"
    }
}
