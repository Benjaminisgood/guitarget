import SwiftUI
import GuitarCore
import GuitarAudio

struct ChordLibraryLesson: View {
    @ObservedObject var audio: AudioService
    @State private var root: PitchClass = .c
    @State private var kind: ChordKind = .major
    @State private var options = ChordSearchOptions()
    @State private var voicings: [ChordVoicing] = []
    @State private var selectedID: String?
    @State private var page = 0
    @State private var isSearching = false
    @State private var searchError: String?
    private let pageSize = 12

    private struct Request: Hashable {
        let chord: ChordDefinition
        let options: ChordSearchOptions
    }
    private var request: Request { Request(chord: ChordDefinition(root: root, kind: kind), options: options) }
    private var selected: ChordVoicing? { voicings.first { $0.id == selectedID } }
    private var pageCount: Int { max(1, (voicings.count + pageSize - 1) / pageSize) }
    private var pageVoicings: ArraySlice<ChordVoicing> { voicings.dropFirst(page * pageSize).prefix(pageSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LearningHeader(eyebrow: "CHORD LIBRARY", title: "找到适合这一句的和弦按法。",
                           subtitle: "十二个根音，十五种常用和弦。看清构成音、转位与手指分工，再比较不同把位的声音。")
            HStack(spacing: 20) {
                RootPicker(root: $root)
                Picker("类型", selection: $kind) {
                    ForEach(ChordKind.allCases) { item in Text(item.title + "  " + (item.suffix.isEmpty ? "major" : item.suffix)).tag(item) }
                }.frame(width: 260)
                Spacer()
                Text(request.chord.name).font(.system(size: 30, weight: .bold, design: .rounded))
            }
            filterCard
            resultHeader
            if let searchError {
                Label(searchError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else if isSearching {
                ProgressView("正在枚举符合条件的按法…").controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
            } else if voicings.isEmpty {
                ContentUnavailableView("此范围内没有完整按法", systemImage: "guitars",
                                       description: Text("可扩大品位范围或品差、增加发声弦数，或允许横按。不会为了显示结果而省略和弦构成音。"))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 185, maximum: 280), spacing: 12)], spacing: 12) {
                    ForEach(pageVoicings) { voicing in voicingButton(voicing) }
                }
                if let selected { selectedCard(selected) }
            }
            DisclosureGroup("枚举与指法的适用范围") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ChordLibrary.fingeringScope)
                    Text("构成音允许重复并分布在不同八度；9 音等扩展音不强制放在根音上方的第二个八度。排序依次优先发声弦之间少留消音空隙、根音低音、低把位、少用指、少横按、窄品差与较多发声弦。按法总数不会截断，分页只影响显示。")
                }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
        }
        .task(id: request) { await search(request) }
        .onDisappear { if audio.ownerID == "和弦库" { audio.stop() } }
    }

    private var filterCard: some View {
        LearningCard(title: "按法筛选", icon: "slider.horizontal.3") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 16) {
                GridRow {
                    Stepper("最低按弦：\(options.minimumFret) 品", value: $options.minimumFret, in: 1...options.maximumFret)
                    Stepper("最高按弦：\(options.maximumFret) 品", value: $options.maximumFret, in: options.minimumFret...24)
                    Stepper("最大品差：\(options.maximumSpan)", value: $options.maximumSpan, in: 0...23)
                }
                GridRow {
                    Stepper("最少发声：\(options.minimumStrings) 弦", value: $options.minimumStrings, in: 1...options.maximumStrings)
                    Stepper("最多发声：\(options.maximumStrings) 弦", value: $options.maximumStrings, in: options.minimumStrings...6)
                    Stepper("最多用指：\(options.maximumFingers)", value: $options.maximumFingers, in: 0...4)
                }
                GridRow {
                    Toggle("允许空弦", isOn: $options.allowOpenStrings)
                    Toggle("允许连续横按", isOn: $options.allowBarre)
                    Toggle("根音作为最低音", isOn: $options.rootInBass)
                }
            }
            Text(options.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var resultHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(isSearching ? "正在搜索 \(request.chord.name)" : "\(request.chord.name) · 共 \(voicings.count) 种按法").font(.headline)
                Text(zip(request.chord.noteNames, request.chord.degrees).map { "\($0.0) (\($0.1))" }.joined(separator: "  ·  "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { changePage(-1) } label: { Image(systemName: "chevron.left") }
                .help("上一页").disabled(isSearching || page == 0)
            Text("\(page + 1) / \(pageCount)").monospacedDigit().foregroundStyle(.secondary)
            Button { changePage(1) } label: { Image(systemName: "chevron.right") }
                .help("下一页").disabled(isSearching || page + 1 >= pageCount)
        }
    }

    private func voicingButton(_ voicing: ChordVoicing) -> some View {
        Button { selectedID = voicing.id } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(voicing.frets.reversed().map { $0.map(String.init) ?? "×" }.joined(separator: " · "))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Spacer(minLength: 2)
                    if selectedID == voicing.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange) }
                }
                Text("6 → 1 弦 · \(voicing.soundingStrings) 弦发声").font(.caption).foregroundStyle(.secondary)
                Text("\(voicing.fingerCount) 指 · \(voicing.barres.count) 处横按 · 低音 \(spelledBass(voicing))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(selectedID == voicing.id ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedID == voicing.id ? Color.orange.opacity(0.6) : Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(voicing.chord.name)，\(voicing.fingeringDescription)")
    }

    private func selectedCard(_ voicing: ChordVoicing) -> some View {
        LearningCard(title: "\(voicing.chord.name) · 当前按法", icon: "hand.draw") {
            HStack(alignment: .top, spacing: 24) {
                ChordVoicingDiagram(voicing: voicing).frame(width: 240)
                VStack(alignment: .leading, spacing: 14) {
                    Text("构成音  " + voicing.chord.noteNames.joined(separator: " · ")).font(.title3.bold())
                    Text("实际最低音  \(spelledBass(voicing))" + (voicing.bassMIDI % 12 == voicing.chord.root.rawValue ? " · 根音低音" : " · 转位"))
                    Text(voicing.fingeringDescription).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text("○ 空弦　× 消音　1 食指 / 2 中指 / 3 无名指 / 4 小指。横线表示同一手指的横按范围，圆点表示该弦实际发声的品位。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button { audio.preview(notes: voicing.notes, owner: "和弦库", strum: true) } label: { Label("扫弦试听", systemImage: "waveform") }
                            .buttonStyle(.borderedProminent)
                        Button { audio.previewSequence(notes: voicing.notes, owner: "和弦库", secondsPerNote: 0.4) } label: { Label("逐弦分解", systemImage: "music.note.list") }
                        Button("停止") { if audio.ownerID == "和弦库" { audio.stop() } }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            FretboardView(positions: voicing.fretPositions, root: voicing.chord.root, maxFret: max(5, voicing.frets.compactMap { $0 }.max() ?? 5),
                          highlightedMIDIs: audio.pitchFrame.map { [$0.midi] } ?? []) { string, fret in
                audio.preview(notes: [GuitarNote(string: string, fret: fret)], owner: "和弦库")
            }.equatable()
        }
    }

    private func spelledBass(_ voicing: ChordVoicing) -> String {
        let index = voicing.chord.pitchClasses.firstIndex(of: voicing.bassMIDI % 12) ?? 0
        return MusicTheory.noteName(midi: voicing.bassMIDI, spelledName: voicing.chord.noteNames[index])
    }
    private func changePage(_ offset: Int) {
        page = min(max(0, page + offset), pageCount - 1)
        selectedID = pageVoicings.first?.id
    }
    @MainActor private func search(_ requested: Request) async {
        if audio.ownerID == "和弦库" { audio.stop() }
        isSearching = true; searchError = nil; voicings = []; selectedID = nil; page = 0
        do {
            try await Task.sleep(nanoseconds: 100_000_000)
            let worker = Task.detached(priority: .userInitiated) {
                try ChordLibrary.voicings(for: requested.chord, options: requested.options, isCancelled: { Task<Never, Never>.isCancelled })
            }
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, requested == request else { return }
            voicings = result; selectedID = result.first?.id; isSearching = false
        } catch is CancellationError {
            // A newer filter task owns the displayed state.
        } catch {
            guard !Task.isCancelled, requested == request else { return }
            searchError = error.localizedDescription; isSearching = false
        }
    }
}

/// Shared with chord practice. The visual order is sixth string on the left.
struct ChordVoicingDiagram: View {
    let voicing: ChordVoicing
    private var firstFret: Int { max(1, voicing.lowestFret) }
    private var rows: Int { max(4, (voicing.frets.compactMap { $0 }.max() ?? 0) - firstFret + 1) }

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 26, right: CGFloat = 18, top: CGFloat = 38, dy: CGFloat = 32
            let dx = (size.width - left - right) / 5
            func point(_ string: Int, _ fret: Int) -> CGPoint {
                CGPoint(x: left + CGFloat(6 - string) * dx, y: top + (CGFloat(fret - firstFret) + 0.5) * dy)
            }
            for string in 1...6 {
                let x = point(string, firstFret).x
                var line = Path(); line.move(to: CGPoint(x: x, y: top)); line.addLine(to: CGPoint(x: x, y: top + CGFloat(rows) * dy))
                context.stroke(line, with: .color(.secondary.opacity(0.45)), lineWidth: 0.7 + Double(string) * 0.14)
                let fret = voicing.frets[string - 1]
                if fret == nil || fret == 0 {
                    context.draw(Text(fret == nil ? "×" : "○").font(.system(size: 16, weight: .medium)).foregroundColor(.secondary), at: CGPoint(x: x, y: 17))
                }
                context.draw(Text("\(string)").font(.system(size: 11)).foregroundColor(.secondary), at: CGPoint(x: x, y: top + CGFloat(rows) * dy + 18))
            }
            for row in 0...rows {
                var line = Path(); line.move(to: CGPoint(x: left, y: top + CGFloat(row) * dy)); line.addLine(to: CGPoint(x: size.width - right, y: top + CGFloat(row) * dy))
                context.stroke(line, with: .color(.secondary.opacity(0.35)), lineWidth: row == 0 && firstFret == 1 ? 3 : 1)
            }
            for barre in voicing.barres {
                var line = Path(); line.move(to: point(barre.fromString, barre.fret)); line.addLine(to: point(barre.toString, barre.fret))
                context.stroke(line, with: .color(.orange.opacity(0.55)), style: StrokeStyle(lineWidth: 12, lineCap: .round))
            }
            for position in voicing.positions {
                guard let fret = position.fret, fret > 0 else { continue }
                let p = point(position.string, fret)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)), with: .color(.orange))
                context.draw(Text("\(position.finger ?? 0)").font(.system(size: 12, weight: .bold)).foregroundColor(.white), at: p)
            }
            context.draw(Text("\(firstFret)").font(.system(size: 11)).foregroundColor(.secondary), at: CGPoint(x: 9, y: top + dy / 2))
        }
        .frame(height: 38 + CGFloat(rows) * 32 + 34)
        .accessibilityLabel("\(voicing.chord.name) 按法图，\(voicing.fingeringDescription)")
    }
}
