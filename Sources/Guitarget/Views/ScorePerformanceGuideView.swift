import SwiftUI
import GuitarCore

/// Read-only cues follow the same score tick as the notation and linked fretboard.
struct ScorePerformanceGuideView: View {
    let context: ScorePerformanceContext
    let voice: ScoreVoice
    @Binding var referenceKey: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text("演奏提示").font(.caption.bold())
                Text(voice.title).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Picker("参考调", selection: $referenceKey) {
                    Text("选择参考调").tag(-1)
                    ForEach(PitchClass.allCases) { root in
                        Text("\(root.displayName) 大调").tag(root.rawValue)
                    }
                    Divider()
                    ForEach(PitchClass.allCases) { root in
                        Text("\(root.displayName) 小调").tag(root.rawValue + 12)
                    }
                }
                .labelsHidden().controlSize(.mini).frame(width: 116)
                .accessibilityLabel("和弦级数参考调")
                .help("按谱面和弦标记选择参考调；变调夹不改变按法之间的级数关系。")
            }
            VStack(alignment: .leading, spacing: 3) {
                lyricRow("前句", phrase: context.previousLyric, emphasis: false)
                lyricRow("当前", phrase: context.currentLyric, emphasis: true)
                lyricRow("后句", phrase: context.nextLyric, emphasis: false)
            }
            if context.previousChord != nil || context.currentChord != nil || context.nextChord != nil {
                HStack(spacing: 6) {
                    chordCell("前一", cue: context.previousChord, current: false)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    chordCell("当前", cue: context.currentChord, current: true)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    chordCell("下一", cue: context.nextChord, current: false)
                }
                .font(.caption2)
            } else {
                Text("暂无和弦标记 · 可在歌词中写 [Am]")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
        .accessibilityIdentifier("score.performanceGuide")
    }

    private func lyricRow(_ title: String, phrase: ScoreLyricPhrase?, emphasis: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
            Text(phrase?.text ?? (emphasis ? (context.nextLyric == nil ? "暂无歌词" : "等待歌词") : "—"))
                .font(.system(size: emphasis ? 13 : 11, weight: emphasis ? .semibold : .regular))
                .foregroundStyle(emphasis ? Color.primary : Color.secondary)
                .lineLimit(1)
                .help(phrase?.text ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chordCell(_ title: String, cue: ScoreChordCue?, current: Bool) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(cue?.symbol ?? "—")
                .font(.system(size: 14, weight: current ? .bold : .medium))
                .foregroundStyle(current ? Color.accentColor : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(degree(for: cue)).font(.system(size: 10, design: .serif))
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(current ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func degree(for cue: ScoreChordCue?) -> String {
        guard let cue else { return " " }
        guard (0..<24).contains(referenceKey), let root = PitchClass(rawValue: referenceKey % 12),
              let chord = ScoreChordSymbol(cue.symbol) else { return "—" }
        return chord.romanNumeral(tonic: root, minor: referenceKey >= 12)
    }
}
