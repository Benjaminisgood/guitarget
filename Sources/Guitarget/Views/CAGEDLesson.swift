import SwiftUI
import GuitarCore
import GuitarAudio

struct CAGEDLesson: View {
    @ObservedObject var audio: AudioService
    @State private var root: PitchClass = .c
    @State private var minor = false
    @State private var shape: ScalePattern = .c
    private var chord: CAGEDChord { CAGEDChord.make(root:root,shape:shape,minor:minor) }
    private var notes: [GuitarNote] { chord.positions.compactMap { p in p.fret.map { GuitarNote(string:p.string,fret:$0) } }.sorted { $0.string > $1.string } }

    var body: some View {
        VStack(alignment:.leading,spacing:26) {
            LearningHeader(eyebrow:"03 / CAGED",title:"五个形状，走遍指板。",subtitle:"形状是手指的排列，和弦名称由实际根音决定。移动形状，听见相同和弦的不同音区。")
            HStack(spacing:20) {
                RootPicker(root:$root)
                Picker("性质",selection:$minor) { Text("大和弦").tag(false);Text("小和弦").tag(true) }.pickerStyle(.segmented).frame(width:200)
                Spacer()
                Text("实际和弦  \(chord.name)").font(.title2.bold())
            }
            HStack(spacing:14) {
                ForEach(ScalePattern.allCases,id:\.self) { item in
                    Button { shape = item } label: {
                        VStack(spacing:12) {
                            HStack { Text("\(item.rawValue) 形状").font(.headline);Spacer();if shape == item { Image(systemName:"checkmark.circle.fill").foregroundStyle(.orange) } }
                            ChordDiagram(chord:CAGEDChord.make(root:root,shape:item,minor:minor))
                        }.padding(14).frame(maxWidth:.infinity)
                            .background(shape == item ? Color.orange.opacity(0.10) : Color.secondary.opacity(0.04),in:RoundedRectangle(cornerRadius:14))
                            .overlay(RoundedRectangle(cornerRadius:14).stroke(shape == item ? .orange.opacity(0.65) : .secondary.opacity(0.15)))
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                Text("\(shape.rawValue) 形状 → \(chord.name)").font(.title3.bold())
                Spacer()
                Button { audio.previewSequence(notes:notes,tuning:[64,59,55,50,45,40],owner:"CAGED",secondsPerNote:0.34) } label:{Label("逐音试听",systemImage:"music.note")}
                Button { audio.preview(notes:notes,tuning:[64,59,55,50,45,40],owner:"CAGED",strum:true) } label:{Label("扫弦试听",systemImage:"waveform")}.buttonStyle(.borderedProminent)
            }
            LearningCard(title:"和弦琶音 · 根音、三音、五音",icon:"guitars") {
                FretboardView(positions:chord.arpeggio,root:root,useDegrees:true,maxFret:max(15,min(24,chord.arpeggio.map(\.fret).max() ?? 15)),highlightedMIDIs:audio.pitchFrame.map { [$0.midi] } ?? []) { string,fret in
                    audio.preview(notes:[GuitarNote(string:string,fret:fret)],tuning:[64,59,55,50,45,40],owner:"CAGED",strum:false)
                }.equatable()
                Text("○ 空弦　× 消音　圆点数字为左手指法（1 食指 / 2 中指 / 3 无名指 / 4 小指）。\(chord.explanation)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ChordDiagram: View {
    let chord: CAGEDChord
    private var lowest: Int { max(1,chord.positions.compactMap(\.fret).filter{$0>0}.min() ?? 1) }
    var body: some View {
        Canvas { context,size in
            let left: CGFloat = 20, top: CGFloat = 28
            let dx = (size.width-left-12)/5, dy: CGFloat = 23
            for index in 0..<6 {
                let x = left + CGFloat(index)*dx
                var line = Path();line.move(to:CGPoint(x:x,y:top));line.addLine(to:CGPoint(x:x,y:top+dy*5))
                context.stroke(line,with:.color(.secondary.opacity(0.5)),lineWidth:0.7+Double(5-index)*0.15)
                let string = 6-index
                let p = chord.positions.first { $0.string == string }
                if let fret = p?.fret, fret > 0 {
                    let y = top + (CGFloat(fret-lowest)+0.5)*dy
                    context.fill(Path(ellipseIn:CGRect(x:x-8,y:y-8,width:16,height:16)),with:.color(.orange))
                    context.draw(Text("\(p?.finger ?? 1)").font(.system(size:10,weight:.bold)).foregroundColor(.white),at:CGPoint(x:x,y:y))
                } else {
                    context.draw(Text(p?.fret == 0 ? "○":"×").font(.system(size:13)).foregroundColor(.secondary),at:CGPoint(x:x,y:12))
                }
                context.draw(Text(["E","A","D","G","B","E"][index]).font(.system(size:9)).foregroundColor(.secondary),at:CGPoint(x:x,y:top+dy*5+12))
            }
            for fret in 0...5 {
                var line=Path();line.move(to:CGPoint(x:left,y:top+CGFloat(fret)*dy));line.addLine(to:CGPoint(x:left+dx*5,y:top+CGFloat(fret)*dy))
                context.stroke(line,with:.color(.secondary.opacity(0.4)),lineWidth:fret == 0 && lowest == 1 ? 3:1)
            }
            context.draw(Text("\(lowest)").font(.system(size:10)).foregroundColor(.secondary),at:CGPoint(x:6,y:top+dy/2))
        }.frame(height:166).accessibilityLabel("\(chord.shape.title) 形状，\(chord.name)")
    }
}
