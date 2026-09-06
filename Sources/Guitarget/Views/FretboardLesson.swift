import SwiftUI
import GuitarCore
import GuitarAudio

struct FretboardLesson: View {
    @ObservedObject var audio: AudioService
    @State private var root: PitchClass = .c
    @State private var degrees = false
    @State private var extended = false
    @State private var chosenNote = GuitarNote(string: 1, fret: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            LearningHeader(eyebrow: "01 / FRETBOARD", title: "让指板，变得熟悉。", subtitle: "点击任意位置，听见它的声音。连接声音、音名和手指的位置。")
            HStack(spacing: 20) {
                RootPicker(root: $root)
                Picker("显示", selection: $degrees) { Text("音名").tag(false); Text("音级").tag(true) }.pickerStyle(.segmented).frame(width:170)
                Toggle("显示至 24 品", isOn: $extended).toggleStyle(.switch).controlSize(.small)
                Spacer()
            }
            LearningCard(title: "标准六弦指板", icon: "guitars") {
                FretboardView(root: root, useDegrees: degrees, maxFret: extended ? 24 : 15, highlightedMIDIs: highlightedMIDIs) { string,fret in
                    chosenNote = GuitarNote(string: string, fret: fret)
                    audio.preview(notes: [chosenNote], tuning: [64,59,55,50,45,40], owner: "指板", strum: false)
                }.equatable()
                HStack(spacing:20) {
                    LegendDot(color:LearningTheme.root,text:"根音")
                    LegendDot(color:LearningTheme.note,text:"其他音")
                    LegendDot(color:.green,text:"检测到的同一音高")
                    Spacer()
                    Text("1 弦最细 · 6 弦最粗").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment:.top,spacing:20) {
                TunerView(audio:audio)
                LearningCard(title:"指板小记",icon:"lightbulb") {
                    Text("十二品 = 高一个八度").font(.title3.bold())
                    Text("每向右移动一品，音高上升一个半音。第十二品比同弦空弦高一个八度，频率加倍。").foregroundStyle(.secondary)
                    Divider()
                    Text("同一个音，可以在多处找到。")
                    Text("识别高亮所有相同音高的位置。仅凭声音无法确定实际演奏的弦与品位。").font(.callout).foregroundStyle(.secondary)
                }
            }
            PracticePanel(audio: audio, score: GuitarScore(title: "指板找音", measures: [ScoreMeasure(voices: [VoiceTrack(voice:.melody, events:[ScoreEvent(startTick:0,notes:[chosenNote])]),VoiceTrack(voice:.bass)])]))
        }
    }

    private var highlightedMIDIs: Set<Int> {
        guard let frame = audio.pitchFrame, frame.confidence > 0.8 else { return [] }
        return [frame.midi]
    }
}
