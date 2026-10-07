import SwiftUI
import GuitarAudio
import GuitarCore

/// Live polyphonic recognition plus a fingering browser, both backed by GuitarCore.
struct ChordTab: View {
    @EnvironmentObject private var audio: AudioService
    @State private var root = PitchClass.c
    @State private var kind = ChordKind.major
    @State private var voicings: [ChordVoicing] = []
    @State private var searchMessage = "选择根音与和弦类型，查找可用指法。"
    private let playbackOwner = "iOS 和弦库"

    private var chord: ChordDefinition { ChordDefinition(root: root, kind: kind) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    IOSHeader(eyebrow: "CHORD / POLYPHONIC", title: "听出你弹的和弦。",
                              subtitle: "开始采集后，扫一个和弦并保持约半秒。")
                    liveCard
                    libraryCard
                }
                .padding(16)
            }
            .navigationTitle("和弦")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: chord.id) { await reload() }
    }

    private var liveCard: some View {
        IOSCard(title: "实时识别", icon: "waveform") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(audio.chordFrame?.chord.label ?? "—")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(audio.chordFrame.map { String(format: "置信度 %.0f%%", $0.confidence * 100) } ?? "等待声音")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Text(audio.chordFrame.map { String(format: "保持 %.2f 秒", $0.heldDuration) } ?? "—")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let frame = audio.chordFrame {
                Text("候选：" + frame.candidates.prefix(4).map { String(format: "%@ %.2f", $0.chord.label, $0.score) }.joined(separator: "  "))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                Text(frame.chord.definition?.noteNames.joined(separator: " · ") ?? frame.chord.pitchClasses.map { MusicTheory.noteName(midi: $0) }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(audio.isCapturing ? "轻扫一个和弦，保持半秒以上。" : "点底部“开始采集”后弹一个和弦。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var libraryCard: some View {
        IOSCard(title: "指法库 · \(chord.name)", icon: "guitars") {
            HStack {
                Picker("根音", selection: $root) {
                    ForEach(PitchClass.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("类型", selection: $kind) {
                    ForEach(ChordKind.allCases) { Text($0.title).tag($0) }
                }
            }
            .pickerStyle(.menu)
            Text(searchMessage).font(.caption).foregroundStyle(.secondary)
            ForEach(voicings.prefix(4)) { voicing in
                HStack(alignment: .center, spacing: 12) {
                    FretDots(frets: voicing.frets, fingers: voicing.fingers)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(voicing.soundingStrings) 根弦 · 最低 \(voicing.lowestFret) 品 · 跨度 \(voicing.fretSpan)")
                            .font(.caption).monospacedDigit()
                        Text(voicing.midiNotes.map { MusicTheory.noteName(midi: $0) }.joined(separator: " "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(spacing: 6) {
                        Button { audio.preview(notes: voicing.notes, owner: playbackOwner, strum: true) } label: {
                            Label("扫弦", systemImage: "play.fill").font(.caption)
                        }
                        Button { audio.previewSequence(notes: voicing.notes, owner: playbackOwner, secondsPerNote: 0.35) } label: {
                            Label("分解", systemImage: "arrow.down.right.and.arrow.up.left").font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func reload() async {
        let target = chord
        let found = await Task.detached(priority: .userInitiated) {
            (try? ChordLibrary.voicings(for: target).prefix(4).map { $0 }) ?? []
        }.value
        voicings = found
        searchMessage = found.isEmpty ? "该和弦在 1–12 品内没有可用的四指指法。" : "按可用指法排序，数字为品位，下方为指法编号。"
    }
}
