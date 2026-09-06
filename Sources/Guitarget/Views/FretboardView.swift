import SwiftUI
import GuitarCore

struct FretboardView: View, Equatable {
    var tuning: [Int] = [64,59,55,50,45,40]
    var positions: [FretPosition]? = nil
    var root: PitchClass = .c
    var useDegrees = false
    var maxFret = 15
    var highlightedMIDIs: Set<Int> = []
    var onPlay: (Int, Int) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tuning == rhs.tuning && lhs.positions == rhs.positions && lhs.root == rhs.root &&
        lhs.useDegrees == rhs.useDegrees && lhs.maxFret == rhs.maxFret && lhs.highlightedMIDIs == rhs.highlightedMIDIs
    }

    private let cellWidth: CGFloat = 55
    private let rowHeight: CGFloat = 45

    var body: some View {
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("弦 / 品").font(.caption2).foregroundStyle(.secondary).frame(width: 58)
                    ForEach(0...maxFret, id: \.self) { fret in
                        Text(fret == 0 ? "空弦" : String(fret))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary).frame(width: cellWidth, height: 32)
                    }
                }
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.brown.opacity(0.09))
                    Canvas { context, size in
                        for fret in 0...maxFret {
                            let x = 58 + CGFloat(fret + 1) * cellWidth
                            var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(line, with: .color(.secondary.opacity(fret == 0 ? 0.6 : 0.18)), lineWidth: fret == 0 ? 4 : 1.5)
                        }
                        for fret in [3,5,7,9,12,15,17,19,21,24] where fret <= maxFret {
                            let x = 58 + CGFloat(fret) * cellWidth + cellWidth / 2
                            let ys: [CGFloat] = fret % 12 == 0 ? [rowHeight * 1.5, rowHeight * 4.5] : [rowHeight * 3]
                            for y in ys { context.fill(Path(ellipseIn: CGRect(x:x-5,y:y-5,width:10,height:10)), with: .color(.secondary.opacity(0.17))) }
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(1...6, id: \.self) { string in
                            HStack(spacing: 0) {
                                VStack(spacing: 2) {
                                    Text("\(string)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                                    Text(noteName(tuning[string-1], octave: false)).font(.system(size: 12, weight: .semibold))
                                }.frame(width: 58, height: rowHeight)
                                ForEach(0...maxFret, id: \.self) { fret in noteCell(string: string, fret: fret) }
                            }
                            .background(alignment: .center) {
                                Rectangle().fill(.secondary.opacity(0.25)).frame(height: CGFloat(string) * 0.27 + 0.4).padding(.leading,58)
                            }
                        }
                    }
                }
                .frame(height: rowHeight * 6)
            }.frame(width: 58 + CGFloat(maxFret+1) * cellWidth)
        }
        .scrollIndicators(.visible)
        .frame(height: rowHeight * 6 + 46)
        .accessibilityLabel("吉他指板，第一弦在上，第六弦在下")
    }

    private func noteCell(string: Int, fret: Int) -> some View {
        let midi = tuning[string-1] + fret
        let position = positions?.first { $0.string == string && $0.fret == fret }
        let visible = positions == nil || position != nil
        let isRoot = position?.isRoot ?? (midi % 12 == root.rawValue)
        let isBlue = position?.isBlue ?? false
        let detected = highlightedMIDIs.contains(midi)
        let color = isRoot ? LearningTheme.root : (isBlue ? LearningTheme.blue : LearningTheme.note)
        let spelledName = position?.name ?? noteName(midi, flats: [.f,.bFlat,.eFlat,.aFlat].contains(root), octave: false)
        let spokenName = MusicTheory.noteName(midi: midi, spelledName: spelledName)
        let label = useDegrees ? (position?.degree ?? intervalName(midi-root.rawValue)) : spelledName
        return Button { onPlay(string, fret) } label: {
            ZStack {
                if visible || detected {
                    Circle().fill(detected ? Color.green : color.opacity(visible ? 0.92 : 0.3))
                    Text(label).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Color.white)
                } else {
                    Circle().fill(.clear)
                }
                if detected { Circle().stroke(Color.green.opacity(0.35), lineWidth: 5).padding(-4) }
            }.frame(width: 29, height: 29).frame(width: cellWidth, height: rowHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("第 \(string) 弦 · \(fret) 品 · \(spokenName)")
        .accessibilityLabel("第\(string)弦第\(fret)品，\(spokenName)")
    }
}
