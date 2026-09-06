import SwiftUI
import AppKit
import GuitarCore

/// Horizontal ink bounds shared by rendering and the measure viewport. A chord
/// occupies one onset; close onsets need enough room for digits, flags and marks.
enum ScoreNotationSpacing {
    static func focusOffset(tick: Int, capacity: Int, contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        guard capacity > 0, viewportWidth > 0, contentWidth > viewportWidth else { return 0 }
        let x = 38 + CGFloat(min(max(0, tick), capacity)) / CGFloat(capacity) * (contentWidth - 60)
        return min(max(0, x - viewportWidth / 2), contentWidth - viewportWidth)
    }

    static func techniqueLabel(_ note: GuitarNote) -> String {
        let mark: String
        switch note.technique {
        case .none, .deadNote: mark = ""
        case .hammerOn: mark = "H"
        case .pullOff: mark = "P"
        case .slide: mark = "/"
        case .bendHalf: mark = "↑½"
        case .bendFull: mark = "↑1"
        case .vibrato: mark = "~"
        case .palmMute: mark = "PM"
        }
        return mark + ([GuitarTechnique.hammerOn, .pullOff, .slide].contains(note.technique) ? note.targetFret.map(String.init) ?? "" : "")
    }

    static func restFragments(_ gap: TickRange) -> [(startTick: Int, ticks: Int)] {
        var fragments: [(startTick: Int, ticks: Int)] = []
        var start = gap.startTick
        let values = [3840, 1920, 960, 480, 320, 240, 120]
        while start < gap.endTick {
            let remaining = gap.endTick - start
            let duration = values.first(where: { $0 <= remaining }) ?? remaining
            fragments.append((start, duration))
            start += duration
        }
        return fragments
    }

    static func minimumWidth(measure: ScoreMeasure, capacity: Int) -> Double {
        guard capacity > 0 else { return 360 }
        var onsets: [Int: (left: Double, right: Double)] = [:]
        func include(_ tick: Int, left: Double, right: Double) {
            guard tick >= 0 && tick < capacity else { return }
            let old = onsets[tick] ?? (0, 0)
            onsets[tick] = (max(old.left, left), max(old.right, right))
        }
        for voice in ScoreVoice.allCases {
            for event in measure.events(for: voice) {
                var right: Double = event.notes.isEmpty ? 8 : (event.rhythm.value.rawValue >= 8 ? 23 : 14)
                if event.rhythm.dotted { right = max(right, 18) }
                for note in event.notes {
                    let mark = techniqueLabel(note)
                    if !mark.isEmpty {
                        // A conservative 9 pt advance covers every glyph in the
                        // actual short technique label at its rendered font size.
                        right = max(right, 20 + Double(mark.count) * 9 / 2)
                    }
                }
                include(event.startTick, left: event.notes.isEmpty ? 8 : 12, right: right)
            }
            for gap in ScoreScheduler.restGaps(in: measure, voice: voice, capacity: capacity) {
                for rest in restFragments(gap) { include(rest.startTick, left: 8, right: 8) }
            }
        }
        let ticks = onsets.keys.sorted()
        var usableWidth = 300.0
        for (previous, next) in zip(ticks, ticks.dropFirst()) {
            let requiredGap = onsets[previous]!.right + onsets[next]!.left + 6
            usableWidth = max(usableWidth, requiredGap * Double(capacity) / Double(next - previous))
        }
        // Keep the final mark inside the right barline as well as apart from its neighbor.
        for tick in ticks {
            usableWidth = max(usableWidth, max(0, onsets[tick]!.right - 10) * Double(capacity) / Double(capacity - tick))
        }
        return ceil(usableWidth + 60)
    }
}

struct ScoreNotationView: View {
    let score: GuitarScore
    let measureIndex: Int
    @ObservedObject var editor: ScoreEditorState
    let playingTick: Int?
    var mutedVoices: Set<ScoreVoice> = []

    private let top: CGFloat = 64
    private let spacing: CGFloat = 20
    var body: some View {
        VStack(spacing: 0) {
            staff
            ForEach(ScoreVoice.allCases) { voice in
                let events = score.measures[measureIndex].events(for: voice)
                    .filter { !($0.lyric?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
                    .sorted { $0.startTick < $1.startTick }
                if !events.isEmpty {
                    ScoreLyricLayout(startTicks: events.map(\.startTick), capacity: score.timeSignature.ticks) {
                        ForEach(events) { event in
                            let selected = editor.measureIndex == measureIndex && editor.tick == event.startTick && editor.voice == voice
                            let active = !mutedVoices.contains(voice) && (playingTick.map { $0 >= event.startTick && $0 < event.endTick } ?? false)
                            Button {
                                editor.voice = voice
                                editor.select(measure: measureIndex, string: event.notes.first?.string ?? editor.string, tick: event.startTick)
                            } label: {
                                Text(event.lyric ?? "")
                                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 3).padding(.vertical, 2)
                                    .foregroundStyle(selected ? Color.accentColor : voice == .melody ? Color.blue : Color.orange)
                                    .background(active ? Color.green.opacity(0.15) : selected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                            }
                            .buttonStyle(.plain)
                            .help("\(voice.title)歌词：\(event.lyric ?? "") · 点击选择对应音符")
                            .accessibilityLabel("第 \(measureIndex + 1) 小节，\(voice.title)，\(event.startTick) ticks，歌词：\(event.lyric ?? "")")
                        }
                    }
                    .padding(.bottom, 9)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var staff: some View {
        Canvas { context, size in
            let margin: CGFloat = 38
            let usable = size.width - margin - 22
            let capacity = score.timeSignature.ticks
            let xFor: (Int) -> CGFloat = { margin + CGFloat($0) / CGFloat(capacity) * usable }
            let measure = score.measures[measureIndex]
            for string in 1...6 {
                let y = top + CGFloat(string - 1) * spacing
                var line = Path(); line.move(to: CGPoint(x: 25, y: y)); line.addLine(to: CGPoint(x: size.width - 12, y: y))
                context.stroke(line, with: .color(.secondary.opacity(0.5)), lineWidth: string > 3 ? 1 : 0.7)
                context.draw(Text("\(string)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: 11, y: y))
            }
            for beat in 0..<score.timeSignature.numerator {
                let tick = beat * 3840 / score.timeSignature.denominator
                let x = xFor(tick)
                var guide = Path(); guide.move(to: CGPoint(x: x, y: 48)); guide.addLine(to: CGPoint(x: x, y: 178))
                context.stroke(guide, with: .color(.secondary.opacity(0.12)), style: StrokeStyle(lineWidth: 0.5, dash: [2,4]))
                context.draw(Text("\(beat + 1)").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7)), at: CGPoint(x: x, y: 225))
            }
            var bars = Path()
            for x: CGFloat in [25, size.width - 12] {
                bars.move(to: CGPoint(x: x, y: top)); bars.addLine(to: CGPoint(x: x, y: top + 5 * spacing))
            }
            context.stroke(bars, with: .color(.primary.opacity(0.6)), lineWidth: 1.2)

            for voice in ScoreVoice.allCases {
                let color: Color = voice == .melody ? .blue : .orange
                let events = measure.events(for: voice)
                for gap in ScoreScheduler.restGaps(in: measure, voice: voice, capacity: capacity) {
                    let restY: CGFloat = voice == .melody ? 27 : 199
                    for rest in ScoreNotationSpacing.restFragments(gap) {
                        let restStart = rest.startTick, duration = rest.ticks
                        drawRest(context: &context, at: CGPoint(x: xFor(restStart), y: restY), ticks: duration, color: color.opacity(0.28))
                        if duration == 320 {
                            context.draw(Text("3").font(.system(size: 9)).foregroundColor(color.opacity(0.4)), at: CGPoint(x: xFor(restStart), y: restY - 14))
                        } else if duration < 120 {
                            context.draw(Text("\(duration)t").font(.system(size: 8)).foregroundColor(color.opacity(0.4)), at: CGPoint(x: xFor(restStart), y: restY + 13))
                        }
                    }
                }
                for event in events {
                    let x = xFor(event.startTick)
                    let selected = editor.measureIndex == measureIndex && editor.tick == event.startTick && editor.voice == voice
                    let active = !mutedVoices.contains(voice) && (playingTick.map { $0 >= event.startTick && $0 < event.endTick } ?? false)
                    if event.notes.isEmpty {
                        // The glyph encodes the base note value. Dots and triplet
                        // marks below change its duration without changing flags.
                        drawRest(context: &context, at: CGPoint(x: x, y: voice == .melody ? 27 : 199), ticks: event.rhythm.value.ticks, color: selected ? .accentColor : color)
                    } else {
                        let ys = event.notes.map { top + CGFloat($0.string - 1) * spacing }
                        let stemEnd: CGFloat = voice == .melody ? 26 : 204
                        let stemStart = voice == .melody ? ys.max()! : ys.min()!
                        if event.rhythm.value != .whole {
                            var stem = Path(); stem.move(to: CGPoint(x: x + 9, y: stemStart)); stem.addLine(to: CGPoint(x: x + 9, y: stemEnd))
                            context.stroke(stem, with: .color(color.opacity(0.8)), lineWidth: 1.1)
                            let flags = event.rhythm.value.rawValue >= 8 ? Int(log2(Double(event.rhythm.value.rawValue / 4))) : 0
                            for index in 0..<flags {
                                let y = stemEnd + CGFloat(index) * (voice == .melody ? 6 : -6)
                                var flag = Path(); flag.move(to: CGPoint(x: x + 9, y: y))
                                flag.addQuadCurve(to: CGPoint(x: x + 18, y: y + (voice == .melody ? 13 : -13)), control: CGPoint(x: x + 23, y: y + (voice == .melody ? 5 : -5)))
                                context.stroke(flag, with: .color(color), lineWidth: 1.5)
                            }
                        }
                        // A compact rhythm cue above/below TAB distinguishes
                        // whole, half and quarter values without a second staff.
                        let head = Path(ellipseIn: CGRect(x: x - (event.rhythm.value == .whole ? 5 : 1),
                                                         y: stemEnd - 3,
                                                         width: event.rhythm.value == .whole ? 12 : 10,
                                                         height: 6))
                        if event.rhythm.value == .whole || event.rhythm.value == .half {
                            context.fill(head, with: .color(Color(nsColor: .textBackgroundColor)))
                            context.stroke(head, with: .color(color), lineWidth: 1.2)
                        } else {
                            context.fill(head, with: .color(color))
                        }
                        for note in event.notes {
                            let y = top + CGFloat(note.string - 1) * spacing
                            let rect = CGRect(x: x - 10, y: y - 9, width: 22, height: 18)
                            let isNoteSelected = selected && note.string == editor.string
                            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(isNoteSelected ? .accentColor : active ? .green.opacity(0.22) : Color(nsColor: .textBackgroundColor)))
                            let fret = note.technique == .deadNote ? "×" : "\(note.fret)"
                            context.draw(Text(fret).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(isNoteSelected ? .white : color), at: CGPoint(x: x + 1, y: y))
                            let marker = ScoreNotationSpacing.techniqueLabel(note)
                            if !marker.isEmpty {
                                context.draw(Text(marker).font(.system(size: 9, weight: .medium)).foregroundColor(color), at: CGPoint(x: x + 20, y: y - 8))
                            }
                            if note.tieToNext {
                                let endX = min(size.width - 12, xFor(event.endTick))
                                var tie = Path(); tie.move(to: CGPoint(x: x + 8, y: y + 8))
                                tie.addQuadCurve(to: CGPoint(x: endX - 6, y: y + 8), control: CGPoint(x: (x + endX) / 2, y: y + 20))
                                context.stroke(tie, with: .color(color), lineWidth: 1)
                            }
                        }
                    }
                    if event.rhythm.dotted {
                        context.fill(Path(ellipseIn: CGRect(x: x + 15, y: voice == .melody ? 28 : 200, width: 3, height: 3)), with: .color(color))
                    }
                    if event.rhythm.triplet {
                        context.draw(Text("3").font(.system(size: 11, weight: .semibold)).foregroundColor(color), at: CGPoint(x: x, y: voice == .melody ? 11 : 216))
                    }
                }
            }
            if editor.measureIndex == measureIndex {
                let x = xFor(editor.tick), y = top + CGFloat(editor.string - 1) * spacing
                context.stroke(Path(roundedRect: CGRect(x: x - 12, y: y - 11, width: 26, height: 22), cornerRadius: 5), with: .color(.accentColor.opacity(0.9)), lineWidth: 1.8)
            }
            if let playingTick {
                let x = xFor(playingTick)
                var cursor = Path(); cursor.move(to: CGPoint(x: x, y: 16)); cursor.addLine(to: CGPoint(x: x, y: 218))
                context.stroke(cursor, with: .color(.green), lineWidth: 2)
            }
        }
        .frame(height: 238)
        .background(Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        .overlay {
            GeometryReader { proxy in
                Color.clear.contentShape(Rectangle()).onTapGesture { point in
                    let relative = (point.x - 38) / (proxy.size.width - 60)
                    let rawTick = min(score.timeSignature.ticks - 1, max(0, Int(relative * Double(score.timeSignature.ticks))))
                    let tolerance = max(50, Int(Double(score.timeSignature.ticks) * 13 / Double(proxy.size.width - 60)))
                    let string = min(6, max(1, Int(((point.y - top) / spacing).rounded()) + 1))
                    editor.selectTime(measure: measureIndex, string: string, approximateTick: rawTick, tolerance: tolerance)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(measureIndex + 1) 小节，\(score.measures[measureIndex].events(for: .melody).count) 个旋律事件，\(score.measures[measureIndex].events(for: .bass).count) 个低音事件。点击选择，数字录入品位。")
    }

    private func drawRest(context: inout GraphicsContext, at point: CGPoint, ticks: Int, color: Color) {
        if ticks >= 1920 {
            let y = point.y + (ticks >= 3840 ? 0 : -4)
            context.fill(Path(CGRect(x: point.x - 5, y: y, width: 10, height: 4)), with: .color(color))
            var line = Path(); line.move(to: CGPoint(x: point.x - 8, y: point.y)); line.addLine(to: CGPoint(x: point.x + 8, y: point.y))
            context.stroke(line, with: .color(color), lineWidth: 0.8)
        } else if ticks >= 960 {
            var p = Path(); p.move(to: CGPoint(x: point.x - 2, y: point.y - 9)); p.addLine(to: CGPoint(x: point.x + 3, y: point.y - 4)); p.addLine(to: CGPoint(x: point.x - 3, y: point.y + 1)); p.addLine(to: CGPoint(x: point.x + 3, y: point.y + 5)); p.addQuadCurve(to: CGPoint(x: point.x - 1, y: point.y + 10), control: CGPoint(x: point.x - 5, y: point.y + 4))
            context.stroke(p, with: .color(color), lineWidth: 2)
        } else {
            let flags = ticks <= 120 ? 3 : ticks <= 240 ? 2 : 1
            var p = Path(); p.move(to: CGPoint(x: point.x + 4, y: point.y - 6)); p.addLine(to: CGPoint(x: point.x - 2, y: point.y + 10))
            context.stroke(p, with: .color(color), lineWidth: 1.4)
            for flag in 0..<flags {
                let y = point.y - 5 + CGFloat(flag * 5)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: y - 3, width: 4, height: 4)), with: .color(color))
                var beam = Path(); beam.move(to: CGPoint(x: point.x - 2, y: y)); beam.addLine(to: CGPoint(x: point.x + 3, y: y - 1))
                context.stroke(beam, with: .color(color), lineWidth: 1)
            }
        }
    }
}

/// Keep lyrics aligned with their onset. Colliding phrases use another row;
/// long phrases wrap at the measured width and increase the measure's height.
private struct ScoreLyricLayout: Layout {
    let startTicks: [Int]
    let capacity: Int

    private func arrangement(width: CGFloat, subviews: Subviews) -> (positions: [CGPoint], sizes: [CGSize], height: CGFloat) {
        let maximumTextWidth = min(180, max(1, width - 24))
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: maximumTextWidth, height: nil)) }
        var laneEnds: [CGFloat] = []
        var laneHeights: [CGFloat] = []
        var lanes: [Int] = []
        var origins: [CGFloat] = []
        for index in subviews.indices {
            let onset = 38 + CGFloat(startTicks[index]) / CGFloat(max(1, capacity)) * max(1, width - 60)
            let x = max(12, min(width - 12 - sizes[index].width, onset - sizes[index].width / 2))
            let lane = laneEnds.firstIndex { $0 + 8 <= x } ?? laneEnds.count
            if lane == laneEnds.count {
                laneEnds.append(0)
                laneHeights.append(0)
            }
            laneEnds[lane] = x + sizes[index].width
            laneHeights[lane] = max(laneHeights[lane], sizes[index].height)
            lanes.append(lane)
            origins.append(x)
        }
        var laneTops: [CGFloat] = []
        var height: CGFloat = 0
        for laneHeight in laneHeights {
            laneTops.append(height)
            height += laneHeight + 4
        }
        let positions = subviews.indices.map { CGPoint(x: origins[$0], y: laneTops[lanes[$0]]) }
        return (positions, sizes, max(0, height - 4))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        return CGSize(width: width, height: arrangement(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            let origin = layout.positions[index]
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), anchor: .topLeading,
                                  proposal: ProposedViewSize(layout.sizes[index]))
        }
    }
}

/// AppKit is used only to enter the native responder chain for score keystrokes.
struct ScoreKeyboardResponder: NSViewRepresentable {
    var focusToken: UUID
    var editor: ScoreEditorState
    func makeNSView(context: Context) -> ScoreKeyView { let view = ScoreKeyView(); view.editor = editor; return view }
    func updateNSView(_ nsView: ScoreKeyView, context: Context) {
        nsView.editor = editor
        nsView.connectUndoManager()
        if nsView.focusToken != focusToken {
            nsView.focusToken = focusToken
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView, let window = nsView.window else { return }
                window.makeFirstResponder(nsView)
            }
        }
    }
}

final class ScoreKeyView: NSView, NSMenuItemValidation {
    var editor: ScoreEditorState?
    private var documentUndoManager: UndoManager?
    var focusToken: UUID?
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { documentUndoManager ?? super.undoManager }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connectUndoManager() }
    func connectUndoManager() {
        guard let window, let editor else { return }
        if documentUndoManager == nil { documentUndoManager = editor.resolveWindowUndoManager(window.undoManager) }
    }
    override func keyDown(with event: NSEvent) { if editor?.handleKey(event) != true { super.keyDown(with: event) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        return editor?.handleKey(event) ?? false
    }
    @objc func undo(_ sender: Any?) { editor?.performUndo() }
    @objc func redo(_ sender: Any?) { editor?.performRedo() }
    @objc func copy(_ sender: Any?) { editor?.copy() }
    @objc func cut(_ sender: Any?) { editor?.cut() }
    @objc func paste(_ sender: Any?) { editor?.paste() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            let name = editor?.undoManager?.undoActionName ?? ""
            menuItem.title = name.isEmpty ? "撤销" : "撤销\(name)"
            return editor?.undoManager?.canUndo == true
        case #selector(redo(_:)):
            let name = editor?.undoManager?.redoActionName ?? ""
            menuItem.title = name.isEmpty ? "重做" : "重做\(name)"
            return editor?.undoManager?.canRedo == true
        case #selector(copy(_:)), #selector(cut(_:)): return editor?.selectedEvent != nil
        case #selector(paste(_:)): return true
        default: return true
        }
    }
}
