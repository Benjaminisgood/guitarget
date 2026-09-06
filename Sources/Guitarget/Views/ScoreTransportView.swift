import SwiftUI
import GuitarCore
import GuitarAudio

/// Every document has one transport. Audio time and live score position are
/// intentionally different quantities when a backing recording is selected.
struct ScoreTransportView: View {
    @ObservedObject var editor: ScoreEditorState
    @ObservedObject var audio: AudioService
    @ObservedObject var reference: ReferenceAudioPlayer
    let entry: LocalScoreLibraryEntry?

    private var usesReference: Bool { editor.audioSource == .reference }
    private var ownsReference: Bool { reference.ownerID == editor.owner && reference.entryID == entry?.id }
    private var referenceTime: Double { ownsReference ? reference.currentTime : 0 }
    private var referenceDuration: Double { ownsReference ? reference.duration : 0 }

    var body: some View {
        HStack(spacing: 10) {
            Picker("音频", selection: Binding(get: { editor.audioSource }, set: editor.selectAudioSource)) {
                Text("曲谱合成").tag(ScoreAudioSource.score)
                Text("无伴奏演奏").tag(ScoreAudioSource.performance)
                if let entry, entry.localAudioFilename != nil {
                    Text(entry.originalAudioName ?? "附加音频").tag(ScoreAudioSource.reference)
                }
            }
            .labelsHidden().frame(width: 185)
            .accessibilityLabel("播放音频来源").accessibilityIdentifier("score.audioSource")
            .help(usesReference ? (entry?.originalAudioName ?? "附加音频") : "选择曲谱合成、无伴奏演奏或附加音频")

            HStack(spacing: 5) {
                Button { editor.playPause() } label: {
                    Image(systemName: editor.transportIsPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }.buttonStyle(.borderedProminent)
                    .help("播放 / 暂停（空格）")
                    .accessibilityLabel(editor.transportIsPlaying ? "暂停播放" : editor.isPerformanceMode ? "开始演奏" : "播放曲谱")
                    .accessibilityIdentifier("score.playPause")
                Button { editor.stopTransport() } label: { Image(systemName: "stop.fill") }.help("停止")
                    .accessibilityIdentifier("score.stop")
                Button { editor.restartTransport() } label: { Image(systemName: "backward.end.fill") }
                    .help(editor.isPerformanceMode ? "从头演奏" : "回到开头")
            }

            Text(audio.ownerID == editor.owner && audio.isCountingIn ? "预备拍" : "第 \(editor.displayTick / max(1, editor.score.timeSignature.ticks) + 1) 小节")
                .font(.system(.caption, design: .monospaced)).fixedSize()

            if usesReference {
                Slider(value: Binding(get: { referenceTime }, set: { reference.seek($0) }), in: 0...max(1, referenceDuration))
                    .disabled(!ownsReference || referenceDuration <= 0)
                    .accessibilityLabel("附加音频播放位置").accessibilityIdentifier("score.playbackPosition")
                    .help("仅定位附加音频；谱面继续根据实际弹奏跟随")
                Text("\(time(referenceTime)) / \(time(referenceDuration))")
                    .font(.system(.caption, design: .monospaced)).monospacedDigit().fixedSize()
            } else if editor.isPerformanceMode {
                ProgressView(value: Double(editor.displayTick), total: Double(max(1, editor.score.totalTicks)))
                    .tint(.green).help("谱面位置由实际弹奏决定")
                Text(editor.performanceExpectedNote.map { "等待 \($0)" } ?? "准备演奏")
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
            } else {
                Slider(value: Binding(get: { Double(editor.displayTick) }, set: { editor.locatePlayback(at: Int($0)) }),
                       in: 0...Double(max(1, editor.score.totalTicks - 1)))
                    .accessibilityLabel("曲谱播放位置").accessibilityValue("\(editor.displayTick) ticks")
                    .accessibilityIdentifier("score.playbackPosition")
                Text("\(ScoreTimeFormatter.text(tick: editor.displayTick, bpm: editor.score.bpm)) / \(ScoreTimeFormatter.text(tick: editor.score.totalTicks, bpm: editor.score.bpm))")
                    .font(.system(.caption, design: .monospaced)).monospacedDigit().fixedSize()
                    .accessibilityLabel("曲谱时间")
            }

            if usesReference {
                speedPicker(value: Binding(get: { reference.rate }, set: { if ownsReference { reference.setRate($0) } }))
                    .disabled(!ownsReference)
            } else if !editor.isPerformanceMode {
                speedPicker(value: $audio.speed)
                Toggle(isOn: $audio.metronomeEnabled) { Image(systemName: "metronome") }.toggleStyle(.button).help("节拍器")
                Toggle("预备拍", isOn: $audio.countInEnabled).toggleStyle(.button)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .alert("无法播放音频", isPresented: Binding(get: { reference.error != nil }, set: { if !$0 { reference.error = nil } })) {
            Button("好") { reference.error = nil }
        } message: { Text(reference.error ?? "") }
    }

    private func speedPicker(value: Binding<Double>) -> some View {
        Picker("变速", selection: value) {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                Text(String(format: "%.2g×", speed)).tag(speed)
            }
        }.frame(width: 100)
    }

    private func time(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
