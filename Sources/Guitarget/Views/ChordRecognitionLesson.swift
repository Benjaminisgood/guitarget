import SwiftUI
import GuitarCore
import GuitarAudio

struct ChordRecognitionLesson: View {
    @ObservedObject var audio: AudioService
    @State private var showAudioSettings = false
    @State private var history: [ChordHistoryEntry] = []
    @State private var now = ProcessInfo.processInfo.systemUptime
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private let playbackOwner = "和弦识别"

    private struct ChordHistoryEntry: Identifiable, Equatable {
        let id = UUID()
        let chord: RecognizedChord
        let startedAt: Double
        var lastSeenAt: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LearningHeader(eyebrow: "CHORD RECOGNITION", title: "听出你弹的和弦。",
                           subtitle: "扫一个和弦，看到和弦名、低音、构成音和十二音级能量。识别完全在本机以原生 Swift 完成：近似复音转录加隐马尔可夫平滑。")
            controls
            LearningCard(title: "实时和弦", icon: "music.quarternote.3") {
                ChordReadout(frame: audio.chordFrame, waitingText: waitingText)
                if let frame = audio.chordFrame { details(frame) }
            }
            LearningCard(title: "十二音级能量", icon: "chart.bar.xaxis") {
                ChromaBars(frame: audio.chordFrame)
                Text("上排为高音区各音级的相对能量，下排小块为低音区能量。橙色为当前和弦的构成音，深橙为根音。").font(.caption).foregroundStyle(.secondary)
            }
            LearningCard(title: "指板上的检测音", icon: "guitars") {
                FretboardView(positions: chordPositions, root: audio.chordFrame?.chord.root ?? .c, useDegrees: true,
                              highlightedMIDIs: Set(audio.chordFrame?.notes.map(\.midi) ?? [])) { string, fret in
                    audio.preview(notes: [GuitarNote(string: string, fret: fret)], owner: playbackOwner)
                }.equatable()
                Text("橙色为当前和弦的根音、青色为其他构成音（标注音级），绿色标出分解出的音高在指板上的全部位置；识别不推断实际按在哪根弦上。点击任意位置试听。").font(.caption).foregroundStyle(.secondary)
            }
            LearningCard(title: "最近识别", icon: "clock.arrow.circlepath") {
                if history.isEmpty { Text("持续 0.25 秒以上的和弦会记录在这里。").foregroundStyle(.secondary) }
                else {
                    ForEach(history.reversed()) { entry in
                        HStack {
                            Text(entry.chord.label).font(.system(size: 20, weight: .bold, design: .rounded)).frame(width: 110, alignment: .leading)
                            Text(entry.chord.kindTitle).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "持续 %.1f 秒 · %@", max(0, entry.lastSeenAt - entry.startedAt), Self.ago(now - entry.lastSeenAt)))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Button("清空记录") { history.removeAll() }.controlSize(.small)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("方法：约 0.34 秒的汉宁窗 FFT 映射到每半音三格的对数频率谱，估计整体音准偏差后按平方根压缩，用非负最小二乘把频谱分解为 E2–B6 各音的显著度（谐波字典由同一分析算子生成），再折叠为十二音级并与 205 个模板（15 种和弦性质 × 12 根音、强力和弦、单音、无和弦）作余弦匹配，最后用带惯性的隐马尔可夫前向滤波得到稳定判定。识别结果以窗口中心时间为准，比实际弹奏晚约 0.2–0.5 秒。离线合成测试覆盖曲库全部 180 种首选按法；真琴、麦克风与房间的准确率尚未测量，扫弦瞬态、极弱的高音弦或非标准调弦都会影响结果。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(audio.$chordFrame) { frame in record(frame) }
        .onReceive(timer) { _ in now = ProcessInfo.processInfo.systemUptime }
        .onChange(of: audio.isCapturing) { _, active in if !active { now = ProcessInfo.processInfo.systemUptime } }
        .onDisappear { if audio.ownerID == playbackOwner { audio.stop() } }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Circle().fill(audio.isCapturing ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            Text(audio.isCapturing ? "\(audio.source.title) · \(audio.status)" : audio.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 12)
            ProgressView(value: audio.isCapturing ? min(1, max(0, audio.inputLevel * 5)) : 0)
                .frame(width: 90).tint(.green).accessibilityLabel("声音输入电平")
            Button { showAudioSettings.toggle() } label: { Label("声音来源", systemImage: "slider.horizontal.3") }
                .popover(isPresented: $showAudioSettings) { AudioSettingsView(audio: audio).padding(22).frame(width: 520) }
        }
    }

    @ViewBuilder private func details(_ frame: ChordFrame) -> some View {
        let tones = frame.chord.noteNames
        VStack(alignment: .leading, spacing: 8) {
            if !tones.isEmpty {
                Text("构成音  " + tones.joined(separator: " · ")).font(.headline)
            }
            Text(frame.notes.isEmpty ? "未分解出明确的音" : "分解出的音  " + frame.notes.map(\.name).joined(separator: " · "))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            let alternatives = frame.candidates.filter { $0.chord != frame.chord.withoutBass }.prefix(2)
            if !alternatives.isEmpty {
                Text("其他候选  " + alternatives.map { "\($0.chord.label) \(String(format: "%.2f", $0.score))" }.joined(separator: " · "))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    /// Every fretboard position of the current chord's tones, so the board reads like the chord library's.
    private var chordPositions: [FretPosition] {
        guard let chord = audio.chordFrame?.chord, let root = chord.root, chord.pitchClasses.count >= 2 else { return [] }
        let classes = chord.pitchClasses, names = chord.noteNames
        var result: [FretPosition] = []
        for string in 1...6 {
            for fret in 0...15 {
                let midi = MusicTheory.standardTuning[string - 1] + fret
                guard let index = classes.firstIndex(of: midi % 12) else { continue }
                result.append(FretPosition(string: string, fret: fret, midi: midi, pitchClass: midi % 12, isRoot: midi % 12 == root.rawValue,
                                           isBlue: false, degree: intervalName(midi % 12 - root.rawValue), name: names.indices.contains(index) ? names[index] : noteName(midi, octave: false)))
            }
        }
        return result
    }

    private var waitingText: String {
        if audio.isStartingCapture { return "正在启动声音采集" }
        if !audio.isCapturing { return "在“声音来源”中启用输入，然后扫一个和弦" }
        return audio.inputLevel > 0.004 ? "正在分析…" : "扫一个和弦，让六根弦一起响"
    }

    private static func ago(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 2 else { return "刚刚" }
        return seconds < 60 ? "\(Int(seconds)) 秒前" : "\(Int(seconds / 60)) 分钟前"
    }

    private func record(_ frame: ChordFrame?) {
        guard let frame, frame.chord != .none, frame.isStable else { return }
        let time = ProcessInfo.processInfo.systemUptime
        if let last = history.last, last.chord == frame.chord, time - last.lastSeenAt < 1.5 {
            history[history.count - 1].lastSeenAt = time
        } else {
            history.append(ChordHistoryEntry(chord: frame.chord, startedAt: time - frame.heldDuration, lastSeenAt: time))
            if history.count > 12 { history.removeFirst(history.count - 12) }
        }
    }
}

struct ChordReadout: View {
    let frame: ChordFrame?
    let waitingText: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(frame.map { $0.chord == .none ? "—" : $0.label } ?? "—")
                .font(.system(size: 76, weight: .semibold, design: .rounded))
                .foregroundStyle(frame == nil || frame?.chord == .none ? Color.secondary.opacity(0.35) : frame?.isStable == true && frame?.chord.isChord == true ? Color.green : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.5)
                .accessibilityLabel("识别结果 \(frame?.label ?? "暂无")")
            VStack(alignment: .leading, spacing: 8) {
                Text(frame.map(\.chord.kindTitle) ?? waitingText).font(.title3)
                if let frame {
                    Text(String(format: "模板匹配 %.0f%% · 置信度 %.0f%%", frame.fit * 100, frame.confidence * 100)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let frame {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(format: "%.1f s", frame.heldDuration)).font(.system(size: 42, weight: .medium, design: .rounded)).monospacedDigit()
                    Text(frame.isStable ? "已持续 · 稳定" : "已持续 · 等待稳定").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "整体音准 %+.0f 音分", frame.tuningCents)).font(.caption).monospacedDigit().foregroundStyle(abs(frame.tuningCents) <= 10 ? Color.secondary : Color.orange)
                }
            }
        }.frame(minHeight: 92)
    }
}

struct ChromaBars: View {
    let frame: ChordFrame?
    private let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    var body: some View {
        let chroma = frame?.chroma ?? [Double](repeating: 0, count: 12)
        let bass = frame?.bassChroma ?? [Double](repeating: 0, count: 12)
        let tones = Set(frame?.chord.pitchClasses ?? [])
        let root = frame?.chord.root?.rawValue
        let peak = max(chroma.max() ?? 0, 1e-9), bassPeak = max(bass.max() ?? 0, 1e-9)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(0..<12, id: \.self) { index in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(index == root ? Color.orange : tones.contains(index) ? Color.orange.opacity(0.65) : Color.secondary.opacity(0.35))
                        .frame(height: max(3, 96 * chroma[index] / peak))
                        .frame(maxHeight: 96, alignment: .bottom)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.indigo.opacity(bass[index] > 0 ? 0.35 + 0.65 * bass[index] / bassPeak : 0.12))
                        .frame(height: 8)
                    Text(names[index]).font(.system(size: 11, weight: index == root ? .bold : .regular, design: .rounded))
                        .foregroundStyle(tones.contains(index) ? Color.primary : Color.secondary)
                }.frame(maxWidth: .infinity)
            }
        }
        .frame(height: 130)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("十二音级能量")
        .accessibilityValue(frame.map { frame in (0..<12).filter { frame.chroma[$0] > 0.3 }.map { names[$0] }.joined(separator: "、") } ?? "暂无")
    }
}
