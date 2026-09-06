import SwiftUI
import GuitarCore

struct TunerReadout: View {
    let reading: TunerReading?
    let waitingText: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(reading.map { MusicTheory.noteName(midi: $0.detectedMIDI) } ?? "—")
                .font(.system(size: 76, weight: .semibold, design: .rounded))
                .foregroundStyle(reading?.isInTune == true ? Color.green : Color.primary)
                .accessibilityLabel("实测音名 \(reading.map { MusicTheory.noteName(midi: $0.detectedMIDI) } ?? "暂无")")
            VStack(alignment: .leading, spacing: 8) {
                Text(reading.map { String(format: "%.2f Hz", $0.frequency) } ?? waitingText).font(.title3).monospacedDigit()
                if let reading {
                    Text(String(format: "置信度 %.0f%%", reading.confidence * 100)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let cents = reading?.cents {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(format: "%+.1f", cents)).font(.system(size: 42, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("音分 · \(abs(cents) <= 5 ? "接近目标" : cents < 0 ? "偏低" : "偏高")").font(.caption).foregroundStyle(.secondary)
                }.foregroundStyle(reading?.isInTune == true ? Color.green : Color.primary)
            }
        }.frame(minHeight: 92)
    }
}

struct TunerCentsMeter: View {
    let cents: Double?
    let inTune: Bool
    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 24)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5).fill(.secondary.opacity(0.12)).frame(height: 12).offset(x: 12, y: 29)
                    RoundedRectangle(cornerRadius: 4).fill(.green.opacity(0.25)).frame(width: width * 0.1, height: 30).offset(x: 12 + width * 0.45, y: 20)
                    ForEach(Array(stride(from: -50, through: 50, by: 10)), id: \.self) { tick in
                        let x = 12 + width * CGFloat(tick + 50) / 100
                        Rectangle().fill(tick == 0 ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: tick == 0 ? 2 : 1, height: tick == 0 ? 40 : 18).offset(x: x, y: tick == 0 ? 15 : 26)
                        Text(tick == 0 ? "0" : String(format: "%+d", tick)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .position(x: x, y: 70)
                    }
                    if let cents {
                        let x = 12 + width * CGFloat(min(50, max(-50, cents)) + 50) / 100
                        Image(systemName: "arrowtriangle.down.fill").font(.system(size: 23)).foregroundStyle(inTune ? Color.green : Color.orange).position(x: x, y: 10)
                        Circle().fill(inTune ? Color.green : Color.orange).frame(width: 12, height: 12).position(x: x, y: 35)
                    }
                }
            }.frame(height: 84)
            HStack {
                Text("♭ 偏低")
                Spacer()
                Text(cents.map { abs($0) > 50 ? "超出 ±50 音分范围" : "中心绿色区 ±5 音分" } ?? "等待可靠读数")
                Spacer()
                Text("偏高 ♯")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("音准表")
        .accessibilityValue(cents.map { String(format: "偏差 %+.1f 音分", $0) } ?? "暂无读数")
    }
}

struct TunerHistoryChart: View {
    let points: [TunerHistoryPoint]
    let now: Double
    var body: some View {
        ZStack {
            Canvas { context, size in
                let plot = CGRect(x: 34, y: 12, width: max(1, size.width - 44), height: max(1, size.height - 32))
                context.fill(Path(CGRect(x: plot.minX, y: plot.midY - plot.height * 0.05, width: plot.width, height: plot.height * 0.1)), with: .color(.green.opacity(0.12)))
                for cents in [-50, 0, 50] {
                    let y = plot.midY - CGFloat(cents) / 100 * plot.height
                    var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
                    context.stroke(line, with: .color(cents == 0 ? .green.opacity(0.6) : .secondary.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: cents == 0 ? [] : [3, 3]))
                    context.draw(Text("\(cents)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: 16, y: y))
                }
                var path = Path()
                var previous: TunerHistoryPoint?
                for point in points where point.timestamp >= now - TunerEngine.historyDuration && point.timestamp <= now {
                    let x = plot.maxX - CGFloat((now - point.timestamp) / TunerEngine.historyDuration) * plot.width
                    let y = plot.midY - CGFloat(min(50, max(-50, point.cents))) / 100 * plot.height
                    let position = CGPoint(x: x, y: y)
                    if let previous, previous.targetID == point.targetID, point.timestamp - previous.timestamp <= 0.3 { path.addLine(to: position) }
                    else { path.move(to: position) }
                    context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)), with: .color(.orange))
                    previous = point
                }
                context.stroke(path, with: .color(.orange), lineWidth: 1.6)
                context.draw(Text("8 秒前").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: plot.minX + 20, y: size.height - 6))
                context.draw(Text("现在").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: plot.maxX - 12, y: size.height - 6))
            }
            if points.isEmpty { Text("等待可靠单音").font(.callout).foregroundStyle(.secondary) }
        }.frame(height: 158)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("最近八秒音分偏差历史")
        .accessibilityValue(points.isEmpty ? "暂无数据" : "\(points.count) 次读数，最近偏差 \(String(format: "%+.1f", points.last?.cents ?? 0)) 音分")
    }
}
