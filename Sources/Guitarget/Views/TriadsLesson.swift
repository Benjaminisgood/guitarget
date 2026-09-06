import SwiftUI
import GuitarCore
import GuitarAudio

struct TriadsLesson: View {
    @ObservedObject var audio: AudioService
    @Environment(\.newDocument) private var newDocument
    @State private var root: PitchClass = .c
    @State private var degree = 1
    @State private var pattern: ScalePattern? = .a
    private var triads:[DiatonicTriad] { DiatonicTriad.all(in:root) }
    private var triad:DiatonicTriad { triads[degree-1] }
    private var positions:[FretPosition] { MusicTheory.fretboard(root:root,kind:.major,pattern:pattern,maxFret:24).filter{triad.pitchClasses.contains($0.pitchClass)} }
    private var exercise:GuitarScore { ExerciseBuilder.score(title:"\(root.displayName) 大调 · \(triad.roman) \(triad.name) 琶音",positions:positions,returnDown:true) }
    var body: some View {
        VStack(alignment:.leading,spacing:26) {
            LearningHeader(eyebrow:"04 / DIATONIC TRIADS",title:"三个音，搭起和声。",subtitle:"在大调音阶中隔一个音叠一个音，得到七个调内三和弦。认识它们的色彩与位置。")
            RootPicker(root:$root)
            HStack(spacing:10) {
                ForEach(triads,id:\.degree) { item in
                    Button { degree = item.degree } label: {
                        VStack(spacing:8) {
                            Text(item.roman).font(.system(size:15,weight:.semibold,design:.serif))
                            Text(item.name).font(.system(size:24,weight:.bold,design:.rounded))
                            Text(item.quality.title).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity).padding(.vertical,18)
                            .background(item.degree == degree ? Color.orange.opacity(0.16):Color.secondary.opacity(0.05),in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                PatternPicker(pattern:$pattern)
                Spacer()
                Text(triad.notes.joined(separator:"  ·  ")).font(.title3.bold())
            }
            LearningCard(title:"\(triad.roman) · \(triad.name) · \(triad.quality.title)",icon:"triangle") {
                FretboardView(positions:triadPositions,root:PitchClass(rawValue:triad.pitchClasses[0])!,useDegrees:true,maxFret:max(15,min(24,positions.map(\.fret).max() ?? 15)),highlightedMIDIs:audio.pitchFrame.map{[$0.midi]} ?? []) { string,fret in
                    audio.preview(notes:[GuitarNote(string:string,fret:fret)],tuning:[64,59,55,50,45,40],owner:"三和弦",strum:false)
                }.equatable()
                Text("显示和弦内的 1、3（或 ♭3）、5（或 ♭5），位置沿用所选大调指型。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button { audio.play(score:exercise,owner:"三和弦",fromTick:0) } label:{Label("琶音试听",systemImage:"play.fill")}.buttonStyle(.borderedProminent)
                Button("停止"){audio.stop()}
                Spacer()
                Button { let snapshot = exercise; newDocument(GuitarScoreDocument(score:snapshot)) } label:{Label("生成琶音练习谱",systemImage:"doc.badge.plus")}
            }
            PracticePanel(audio:audio,score:exercise)
        }
    }
    private var triadPositions:[FretPosition] {
        positions.map { p in
            var result = p
            result.isRoot = p.pitchClass == triad.pitchClasses[0]
            result.degree = intervalName(p.pitchClass-triad.pitchClasses[0])
            return result
        }
    }
}
