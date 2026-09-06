import SwiftUI
import GuitarCore
import GuitarAudio

struct EnsembleLesson: View {
    @ObservedObject var audio: AudioService
    @Environment(\.newDocument) private var newDocument
    @State private var root: PitchClass = .c
    @State private var style: JamStyle = .folk
    @State private var bpm: Double = 80
    @State private var arrangement = JamBuilder.make(root: .c, style: .folk)
    @State private var recommendation: JamRecommendation = .chordTones
    @State private var degrees = false
    @State private var maxFret = 15
    @State private var selectedMeasure = 0
    @State private var selectedNote: GuitarNote?
    @State private var looping = true
    @State private var metronome = false
    @State private var countIn = true
    @State private var challenge = 0
    @State private var auditionTick: Int?
    @State private var auditionWasPlaying = false
    @State private var status = "选一个伴奏，先用每小节的根音开始。"
    @State private var owner = "合奏-\(UUID().uuidString)"
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private var controlsLocked: Bool { audio.ownerID == owner && (audio.isPlaying || audio.isPaused) || auditionTick != nil }
    private var tick: Int { audio.ownerID == owner ? audio.currentTick : auditionTick ?? selectedMeasure * 3840 }
    private var chord: JamChord { arrangement.chord(atTick: tick) }
    private var positions: [FretPosition] { arrangement.recommendations(atTick: tick, mode: recommendation, maxFret: maxFret) }
    private let challenges = ["每小节第一拍弹根音，其余拍休息，听清和弦如何变化。", "用当前和弦的 1、3、5 音分解；换和弦时找最近的下一个音。", "用五声音阶弹两小节，再留两小节空白，重复并轻微改变节奏。", "每句末音落到当前和弦音；挑同弦相邻音练击弦、勾弦或滑音。"]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LearningHeader(eyebrow: "PLAY TOGETHER", title: "让每个音，都有音乐陪伴。", subtitle: "四种原创吉他伴奏，本地合成、自由转调。跟随和弦变化选择音符，从落稳根音到写出自己的乐句。")
            HStack(spacing: 18) {
                RootPicker(root: $root)
                Picker("伴奏", selection: $style) { ForEach(JamStyle.allCases) { Text($0.title).tag($0) } }.frame(width: 230)
                Stepper("\(Int(bpm)) BPM", value: $bpm, in: 40...180, step: 2).frame(width: 160)
                Spacer()
                Button("打开伴奏曲谱") { newDocument(GuitarScoreDocument(score: arrangement.score)) }
            }.disabled(controlsLocked)
            LearningCard(title: style.description, icon: "waveform") {
                HStack(spacing: 14) {
                    Button {
                        if audio.ownerID == owner && audio.isPlaying { audio.pause() }
                        else if audio.ownerID == owner && audio.isPaused { audio.resume() }
                        else { play(from: selectedMeasure * 3840, countIn: countIn) }
                    } label: { Label(audio.ownerID == owner && audio.isPlaying ? "暂停伴奏" : audio.ownerID == owner && audio.isPaused ? "继续伴奏" : "开始合奏", systemImage: audio.ownerID == owner && audio.isPlaying ? "pause.fill" : "play.fill") }
                        .buttonStyle(.borderedProminent).disabled(auditionTick != nil)
                    Button("停止") { stop() }.disabled(!controlsLocked)
                    Toggle("循环", isOn: $looping).disabled(controlsLocked)
                    Toggle("预备拍", isOn: $countIn).disabled(controlsLocked)
                    Toggle("节拍器", isOn: $metronome).disabled(controlsLocked)
                    Spacer()
                    Text(audio.ownerID == owner && audio.isCountingIn ? "预备拍…" : "第 \(chord.measure + 1) / \(arrangement.chords.count) 小节").monospacedDigit()
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(arrangement.chords) { item in
                            Button {
                                selectedMeasure = item.measure
                                if audio.ownerID == owner { audio.seek(to: item.measure * 3840) }
                                selectedNote = nil
                            } label: {
                                VStack(spacing: 6) {
                                    Text("\(item.measure + 1)").font(.caption2).foregroundStyle(.secondary)
                                    Text(item.name).font(.title2.bold())
                                    Text(item.roman).font(.caption)
                                }.frame(width: 82).padding(.vertical, 12)
                                    .background(item.measure == chord.measure ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(item.measure == chord.measure ? .orange : .clear))
                            }.buttonStyle(.plain).disabled(auditionTick != nil)
                                .accessibilityLabel("定位第\(item.measure + 1)小节，\(item.name)")
                        }
                    }
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            LearningCard(title: "\(chord.name) · \(chord.noteNames.joined(separator: " / "))", icon: "guitars") {
                HStack {
                    Picker("推荐音符", selection: $recommendation) { ForEach(JamRecommendation.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 440)
                    Toggle("音级", isOn: $degrees)
                    Spacer()
                    Picker("品位范围", selection: $maxFret) { Text("12 品").tag(12); Text("15 品").tag(15); Text("24 品").tag(24) }.frame(width: 140)
                }
                FretboardView(positions: positions, root: recommendation == .chordTones ? chord.root : root, useDegrees: degrees, maxFret: maxFret, highlightedMIDIs: audio.pitchFrame.map { [$0.midi] } ?? []) { string, fret in
                    guard positions.contains(where: { $0.string == string && $0.fret == fret }) else { return }
                    let note = GuitarNote(string: string, fret: fret)
                    selectedNote = note
                    if !controlsLocked { audio.preview(notes: [note], owner: owner + "选音") }
                }.equatable()
                HStack {
                    if let note = selectedNote {
                        Text("已选：第 \(note.string) 弦 \(note.fret) 品 · \(selectedNoteName(note))")
                        Button(controlsLocked ? "暂停伴奏并试听" : "试听选音") { audition(note) }.disabled(auditionTick != nil)
                    } else { Text("点击有标记的位置选择一个目标音。") }
                    Spacer()
                }.font(.callout)
                Text(recommendation == .chordTones ? "橙色是当前和弦的根音；音级相对当前和弦。第一拍与乐句结尾优先落在这些音。" : "橙色与音级相对伴奏主调。经过音并非在每个和弦上都同样稳定；结束时可切回当前和弦音找落点。布鲁斯允许大小三度形成张力。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("伴奏中点击指板只选择目标；试听会暂时暂停伴奏，听完后从原位置继续。绿色为输入音高对应位置，不判断实际弦位。麦克风合奏建议使用耳机。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LearningCard(title: "从基本功到即兴", icon: "sparkles") {
                Picker("练习任务", selection: $challenge) {
                    Text("1 · 根音落拍").tag(0); Text("2 · 和弦连接").tag(1); Text("3 · 问答乐句").tag(2); Text("4 · 技巧即兴").tag(3)
                }.pickerStyle(.segmented)
                Text(challenges[challenge])
                Button("生成当前推荐音练习谱") {
                    var score = ExerciseBuilder.score(title: "\(chord.name) · \(recommendation.title)", positions: positions, returnDown: true)
                    score.bpm = bpm
                    newDocument(GuitarScoreDocument(score: score))
                }
                Text("此处自由合奏不评分；可在生成的单音练习谱中使用“弹对再前进”或按节拍跟练。伴奏为程序编写的练习编配，未使用商业录音。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: root) { _, _ in rebuild() }
        .onChange(of: style) { _, value in bpm = value.defaultBPM; rebuild() }
        .onChange(of: bpm) { _, _ in rebuild() }
        .onChange(of: recommendation) { _, _ in selectedNote = nil }
        .onChange(of: chord.measure) { _, _ in selectedNote = nil }
        .onReceive(timer) { _ in
            guard let resumeTick = auditionTick else { return }
            if audio.ownerID == owner + "选音", !audio.isPlaying, !audio.isPaused {
                auditionTick = nil; play(from: resumeTick, countIn: false)
                if !auditionWasPlaying { audio.pause() }
            } else if audio.ownerID != owner + "选音" {
                auditionTick = nil; status = "其他窗口已接管声音；点击开始合奏重新进入。"
            }
        }
        .onDisappear { stop() }
    }

    private func rebuild() {
        guard !controlsLocked else { return }
        arrangement = JamBuilder.make(root: root, style: style, bpm: bpm)
        selectedMeasure = 0; selectedNote = nil
    }
    private func selectedNoteName(_ note: GuitarNote) -> String {
        let midi = MusicTheory.standardTuning[note.string - 1] + note.fret
        let spelling = positions.first { $0.string == note.string && $0.fret == note.fret }?.name
        return spelling.map { MusicTheory.noteName(midi: midi, spelledName: $0) } ?? MusicTheory.noteName(midi: midi)
    }
    private func play(from tick: Int, countIn: Bool) {
        audio.playAccompaniment(score: arrangement.score, owner: owner, loop: looping, metronome: metronome, countIn: countIn, fromTick: tick)
        status = "跟随当前和弦弹奏；和弦卡片可直接定位。"
    }
    private func stop() {
        if audio.ownerID == owner { selectedMeasure = chord.measure; audio.stop() }
        else if audio.ownerID == owner + "选音" { audio.stop() }
        auditionTick = nil
        status = "已停止，选择一个小节可从那里重新开始。"
    }
    private func audition(_ note: GuitarNote) {
        if audio.ownerID == owner, audio.isPlaying || audio.isPaused {
            auditionTick = audio.currentTick; auditionWasPlaying = audio.isPlaying
        }
        audio.preview(notes: [note], owner: owner + "选音")
    }
}
