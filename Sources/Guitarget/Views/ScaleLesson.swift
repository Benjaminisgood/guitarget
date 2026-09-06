import SwiftUI
import GuitarCore
import GuitarAudio

struct ScaleLesson: View {
    @ObservedObject var audio: AudioService
    @Environment(\.newDocument) private var newDocument
    @State private var root: PitchClass = .c
    @State private var kind: ScaleKind = .major
    @State private var pattern: ScalePattern? = .a
    @State private var degrees = false
    @State private var extended = false

    private var positions: [FretPosition] { MusicTheory.fretboard(root:root,kind:kind,pattern:pattern,maxFret:pattern == nil && !extended ? 15 : 24) }
    private var exercise: GuitarScore { ExerciseBuilder.score(title:"\(root.displayName) \(kind.title) · \(pattern?.title ?? "全指板")",positions:positions,returnDown:true) }

    var body: some View {
        VStack(alignment:.leading,spacing:26) {
            LearningHeader(eyebrow:"02 / SCALES",title:"把一个个音，连成旋律。",subtitle:"六类音阶，十二个根音，五种相连的 CAGED 指型。先听，再看，再弹。")
            HStack(spacing:20) {
                RootPicker(root:$root)
                Picker("音阶",selection:$kind) { ForEach(ScaleKind.allCases,id:\.self) { Text($0.title).tag($0) } }.frame(width:230)
                Toggle("音级",isOn:$degrees).toggleStyle(.switch).controlSize(.small)
                Toggle("全指板 24 品",isOn:$extended).toggleStyle(.switch).controlSize(.small).disabled(pattern != nil)
            }
            PatternPicker(pattern:$pattern)
            HStack(spacing:10) {
                ForEach(Array(MusicTheory.spelledNotes(root:root,kind:kind).enumerated()),id:\.offset) { index,name in
                    VStack(spacing:6) {
                        Text(name).font(.system(size:23,weight:.bold,design:.rounded))
                        Text(intervalName(kind.intervals[index])).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
                    }.frame(width:65,height:70).background(index == 0 ? Color.orange.opacity(0.15) : Color.teal.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
                }
                Spacer()
                VStack(alignment:.trailing,spacing:5) {
                    Text("关系调").font(.caption).foregroundStyle(.secondary)
                    Text(relativeKey).font(.headline)
                }
            }
            LearningCard(title:"\(root.displayName) \(kind.title)",icon:"music.note.list") {
                FretboardView(positions:positions,root:root,useDegrees:degrees,maxFret:extended ? 24 : max(15,min(24,(positions.map(\.fret).max() ?? 15))),highlightedMIDIs:highlighted) { string,fret in
                    audio.preview(notes:[GuitarNote(string:string,fret:fret)],tuning:[64,59,55,50,45,40],owner:"音阶",strum:false)
                }.equatable()
                HStack(spacing:18) {
                    LegendDot(color:.orange,text:"根音")
                    LegendDot(color:.teal,text:"音阶内音")
                    LegendDot(color:.indigo,text:"蓝调音")
                    Spacer()
                    Text(pattern == nil ? "全指板包含显示范围内的所有对应音" : pattern!.explanation).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button { audio.play(score:exercise,owner:"音阶",fromTick:0) } label:{ Label("上下行试听",systemImage:"play.fill") }.buttonStyle(.borderedProminent)
                Button("停止") { audio.stop() }
                Spacer()
                Button { let snapshot = exercise; newDocument(GuitarScoreDocument(score:snapshot)) } label:{ Label("生成练习谱",systemImage:"doc.badge.plus") }
            }
            PracticePanel(audio:audio,score:exercise)
        }
    }
    private var highlighted: Set<Int> { audio.pitchFrame.map { [$0.midi] } ?? [] }
    private var relativeKey: String {
        MusicTheory.relativeKeyDescription(root:root,kind:kind)
    }
}
