import SwiftUI
import AVFoundation
import GuitarCore
import GuitarAudio

struct ChordPracticeLesson: View {
    @ObservedObject var audio: AudioService
    @State private var style: ChordPracticeStyle = .diagram
    @State private var assessment: ChordPracticeAssessment = .singleNotes
    @State private var roots: Set<PitchClass> = [.c, .g, .d, .a, .e]
    @State private var collection = ChordPracticeCollection.both
    @State private var rounds = 8
    @State private var memorySeconds = 5
    @State private var session = ChordPracticeSession()
    @State private var owner = "和弦练习-\(UUID().uuidString)"
    @State private var error: String?
    @State private var preparingTask: Task<[ChordPracticeCard], Error>?
    @State private var isPreparing = false
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LearningHeader(eyebrow: "CHORD PRACTICE", title: "把和弦记在手上。", subtitle: "看图、听示范、限时记忆。逐弦检查音高，再用自己的耳朵判断扫弦是否清晰。")
            settings
            if let card = session.currentCard, session.isActive {
                training(card)
            } else {
                LearningCard(title: session.phase == .finished ? "这一组已结束" : "准备开始", icon: "hand.draw") {
                    Text(session.phase == .finished ? "已完成 \(session.results.count) / \(session.cards.count) 轮。可调整根音与和弦集合，再练一组。" : "选择根音、训练方式和轮数。关闭采集也能看图、听示范、记忆和自评。")
                        .foregroundStyle(.secondary)
                    if isPreparing { ProgressView("正在准备按法…") }
                    else { Button(session.phase == .finished ? "再练一组" : "开始练习", action: start).buttonStyle(.borderedProminent).disabled(roots.isEmpty) }
                }
            }
            if !session.results.isEmpty { results }
            Text("逐弦判定使用 YIN 单音音高：每弦重新起音，音准 ±25 音分并稳定 120 ms；它不判断实际按在哪根弦。整和弦判定使用复音和弦识别：扫弦后识别出的根音与性质需与目标一致并持续 0.3 秒，转位或低音不同只作提示。两种自动判定都不评价扫弦质量。麦克风练习建议戴耳机；逐弦判定时拨下一根前请消掉前一根的余音。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(timer) { _ in tick() }
        .onReceive(audio.pitchFrames) { frame in
            session.setAudioContext(capturing: audio.isCapturing, playbackBlocking: audio.isPlaying || audio.isPaused, at: hostTime())
            session.consume(PitchObservation(timestamp: frame.timestamp, frequency: frame.frequency, cents: frame.cents,
                                             confidence: frame.confidence, rms: frame.rms, isStable: frame.isStable, onsetTimestamp: frame.onsetTimestamp))
        }
        .onReceive(audio.chordFrames) { frame in
            session.setAudioContext(capturing: audio.isCapturing, playbackBlocking: audio.isPlaying || audio.isPaused, at: hostTime())
            session.consume(frame)
        }
        .onDisappear { finish() }
        .alert("无法开始练习", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var settings: some View {
        LearningCard(title: "这一组练什么", icon: "slider.horizontal.3") {
            HStack(spacing: 20) {
                Picker("训练方式", selection: $style) { ForEach(ChordPracticeStyle.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).frame(maxWidth: 440)
                Picker("判定方式", selection: $assessment) { ForEach(ChordPracticeAssessment.allCases) { Text($0.title).tag($0) } }.frame(width: 240)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("根音").font(.callout.bold())
                    Spacer()
                    Button(roots.count == 12 ? "清空" : "全选") { roots = roots.count == 12 ? [] : Set(PitchClass.allCases) }.controlSize(.small)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 8)], spacing: 8) {
                    ForEach(PitchClass.allCases) { root in
                        Button { if roots.contains(root) { roots.remove(root) } else { roots.insert(root) } } label: {
                            Text(root.displayName).font(.system(.callout, design: .rounded).bold()).frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).tint(roots.contains(root) ? .orange : .secondary)
                            .accessibilityLabel("\(root.displayName) 根音，\(roots.contains(root) ? "已选择" : "未选择")")
                    }
                }
            }
            HStack(spacing: 28) {
                Picker("和弦集合", selection: $collection) { ForEach(ChordPracticeCollection.allCases) { Text($0.title).tag($0) } }.frame(width: 220)
                Stepper("\(rounds) 轮", value: $rounds, in: 1...40).frame(width: 135)
                if style == .memory { Stepper("记忆 \(memorySeconds) 秒", value: $memorySeconds, in: 2...20).frame(width: 170) }
                Spacer()
            }
            Text(assessmentCaption).font(.caption).foregroundStyle(.secondary)
        }
        .disabled(session.isActive || isPreparing)
        .overlay(alignment: .topTrailing) {
            if session.isActive || isPreparing { Button(isPreparing ? "取消准备" : "结束这一组", action: finish).padding(16) }
        }
    }

    private var assessmentCaption: String {
        switch assessment {
        case .singleNotes: return "由粗弦到细弦逐根拨弦（6→1，跳过消音弦）；只记录单音是否通过，最后由你自评和弦。"
        case .wholeChord: return "扫响整个和弦并保持；识别出的根音与和弦性质与目标一致并持续 0.3 秒即通过。低音不同会提示转位，最后仍由你自评。"
        case .selfAssessment: return "弹完整和弦后自评。此方式不进行自动评分。"
        }
    }

    private func training(_ card: ChordPracticeCard) -> some View {
        LearningCard(title: "第 \(session.index + 1) / \(session.cards.count) 轮 · \(session.style.title)", icon: "guitars") {
            HStack(alignment: .top, spacing: 30) {
                VStack(spacing: 10) {
                    if session.diagramVisible {
                        Text(card.chord.name).font(.system(size: 36, weight: .bold, design: .rounded))
                        ChordVoicingDiagram(voicing: card.voicing)
                        Text("○ 空弦　× 消音　数字为左手指号").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: session.phase == .listening ? "ear" : "eye.slash").font(.system(size: 48)).foregroundStyle(.orange)
                            Text(session.phase == .listening ? "先听示范" : "指法已隐藏").font(.title2.bold())
                            Text("演奏后揭晓和弦与按法").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).frame(height: 275)
                    }
                }.frame(width: 265)
                VStack(alignment: .leading, spacing: 16) {
                    phaseContent(card)
                    if !session.notice.isEmpty { Text(session.notice).font(.callout).foregroundStyle(.orange) }
                    if session.phase == .performing || session.phase == .review {
                        HStack {
                            Button { demonstrate(strum: false) } label: { Label("再听分解", systemImage: "music.note") }
                            Button { demonstrate(strum: true) } label: { Label("扫弦示范", systemImage: "speaker.wave.2") }
                            if !session.diagramVisible { Button("看图提示") { session.revealDiagram() } }
                        }.controlSize(.small)
                        if session.currentResult == nil {
                            Divider()
                            Text("自评：按弦与扫弦是否清晰？").font(.headline)
                            HStack {
                                ForEach(ChordSelfRating.allCases) { rating in
                                    Button(rating.title) { session.rate(rating, at: hostTime()) }
                                }
                            }
                            Text("自评是你的判断，不会计入自动单音通过率。未检查的弦不会自动算作通过。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button(session.index + 1 == session.cards.count ? "查看本组结果" : "下一轮", action: next)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func phaseContent(_ card: ChordPracticeCard) -> some View {
        switch session.phase {
        case .memorizing:
            Text("还有 \(max(0, Int(ceil((session.memoryDeadline ?? hostTime()) - hostTime())))) 秒").font(.largeTitle.bold()).monospacedDigit()
            Text("记住消音弦、空弦与左手位置。倒计时结束后图示和目标音名会隐藏，再凭记忆弹奏。")
        case .awaitingDemonstration:
            Text("先听一遍，再用吉他复现。").font(.title2.bold())
            HStack { Button("播放分解示范") { demonstrate(strum: false) }; Button("跳过示范并看图") { session.skipPreparation(at: hostTime()) } }
        case .listening:
            Text("示范试听中").font(.title2.bold())
            Text("自动判定已暂停。听完后重新拨弦开始，示范余音不会计入结果。")
            if audio.ownerID == owner { Button("停止示范") { audio.stop(); session.finishDemonstration(completed: false, at: hostTime()) } }
        case .performing:
            if session.assessment == .singleNotes {
                let index = min(session.engine.index, max(0, card.notes.count - 1))
                Text("第 \(index + 1) / \(card.notes.count) 根发声弦").font(.title2.bold())
                if card.notes.indices.contains(index) {
                    let note = card.notes[index]
                    Text(session.diagramVisible ? "\(note.string) 弦 · \(note.fret) 品 · \(session.engine.currentTarget?.title ?? "")" : "由粗弦到细弦，请拨 \(note.string) 弦")
                        .font(.headline).foregroundStyle(.orange)
                }
                ProgressView(value: session.engine.progress).tint(.orange)
                Text(session.playbackBlocking ? "当前有示范或其他模块播放，自动判定暂停。" : !session.captureEnabled ? "采集已关闭。可手动继续或直接自评；启用采集后自动恢复单音检查。" : session.diagramVisible ? session.engine.status : "等待新的单音起音，并保持音准稳定。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("此弦手动继续（不算通过）") { session.skipString(at: hostTime()) }.disabled(session.playbackBlocking)
            } else if session.assessment == .wholeChord {
                Text(session.diagramVisible ? "扫响 \(card.chord.name)，保持 0.3 秒" : "扫响整个和弦，保持 0.3 秒").font(.title2.bold())
                if let live = audio.chordFrame, live.chord != .none, session.canConsumeChords {
                    Text("正在听到：\(live.label) · \(live.chord.kindTitle) · 已持续 \(String(format: "%.1f", live.heldDuration)) 秒")
                        .font(.headline).foregroundStyle(.orange).monospacedDigit()
                }
                if let heard = session.recognition { Text(heard.description).font(.callout).foregroundStyle(.secondary) }
                Text(session.playbackBlocking ? "当前有示范或其他模块播放，自动判定暂停。" : !session.captureEnabled ? "采集已关闭。可手动继续或直接自评；启用采集后自动恢复和弦识别。" : "需要提示之后的新一次扫弦；示范余音不计入。识别有约半秒延迟，请让和弦响够。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("手动继续（不算通过）") { session.skipRecognition(at: hostTime()) }.disabled(session.playbackBlocking)
            } else {
                Text("弹完整和弦，再自行评价。").font(.title2.bold())
                Text("此方式不进行自动识别或评分；需要自动判定请选择“整和弦识别判定”。没有启用采集也可以完成训练。")
                    .foregroundStyle(.secondary)
            }
        case .review:
            Text("揭晓：\(card.chord.name)").font(.title2.bold())
            if session.assessment == .singleNotes {
                Text("逐弦自动通过 \(session.engine.results.filter { $0.outcome == .correct }.count) / \(card.notes.count) · 手动跳过 \(session.engine.results.filter { $0.outcome == .manual }.count)")
            } else if session.assessment == .wholeChord {
                Text(session.recognition.map { $0.matchesTarget ? "整和弦识别通过 · \($0.description)" : "手动继续 · 最后\($0.description)" } ?? "手动继续 · 未识别到目标和弦")
            }
            if let result = session.currentResult { Text("自评：\(result.rating.title)\(result.usedHint ? " · 使用了提示" : "")").foregroundStyle(.secondary) }
            else { Text(session.assessment == .wholeChord ? "自动识别完成。请再自行判断按弦与扫弦是否清晰。" : "单音检查完成。请再自行判断和弦整体是否清晰。") }
        default: EmptyView()
        }
    }

    private var results: some View {
        LearningCard(title: "本组记录 · 自动结果与自评分开", icon: "list.bullet.clipboard") {
            HStack(spacing: 26) {
                Text("完成 \(session.results.count) 轮").font(.headline)
                if session.results.contains(where: { $0.assessment == .singleNotes }) {
                    Text("单音自动通过 \(session.results.reduce(0) { $0 + $1.automaticallyPassed }) 根")
                }
                if session.results.contains(where: { $0.assessment == .wholeChord }) {
                    Text("整和弦识别通过 \(session.results.filter(\.recognisedCorrectly).count) 轮")
                }
                Text("自评熟练 \(session.results.filter { $0.rating == .confident }.count) 轮")
                Spacer()
            }
            ForEach(session.results) { result in
                HStack {
                    Text(result.card.chord.name).font(.headline).frame(width: 85, alignment: .leading)
                    Text(automaticSummary(result)).foregroundStyle(.secondary)
                    Spacer()
                    if result.usedHint { Text("使用提示").font(.caption).foregroundStyle(.secondary) }
                    Text("自评：\(result.rating.title)")
                }.font(.callout)
            }
        }
    }

    private func automaticSummary(_ result: ChordPracticeRoundResult) -> String {
        switch result.assessment {
        case .singleNotes: return "单音自动通过 \(result.automaticallyPassed)/\(result.card.notes.count) · 手动跳过 \(result.manuallySkipped)"
        case .wholeChord: return result.recognition.map { $0.matchesTarget ? "整和弦识别通过 · 听到 \($0.heard.label)" : "手动继续 · 最后听到 \($0.heard.label)" } ?? "手动继续 · 未识别到目标"
        case .selfAssessment: return "扫弦自评 · 未进行自动评分"
        }
    }

    private func hostTime() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

    private func start() {
        guard !isPreparing else { return }
        let selectedRoots = Array(roots), selectedKinds = collection.kinds, requestedRounds = rounds
        isPreparing = true
        let task = Task.detached(priority: .userInitiated) {
            var random = SystemRandomNumberGenerator()
            return try ChordPracticeDeck.make(roots: selectedRoots, kinds: selectedKinds, rounds: requestedRounds, using: &random, isCancelled: { Task.isCancelled })
        }
        preparingTask = task
        Task { @MainActor in
            do {
                let cards = try await task.value
                guard !task.isCancelled else { return }
                preparingTask = nil; isPreparing = false
                session.start(cards: cards, style: style, assessment: assessment, memorySeconds: Double(memorySeconds), at: hostTime())
                session.setAudioContext(capturing: audio.isCapturing, playbackBlocking: audio.isPlaying || audio.isPaused, at: hostTime())
                if session.phase == .awaitingDemonstration { demonstrate(strum: false) }
            } catch {
                guard !task.isCancelled else { return }
                preparingTask = nil; isPreparing = false; self.error = error.localizedDescription
            }
        }
    }

    private func demonstrate(strum: Bool) {
        guard let card = session.currentCard else { return }
        session.beginDemonstration(at: hostTime())
        if strum { audio.preview(notes: card.notes, owner: owner, strum: true) }
        else { audio.previewSequence(notes: card.notes, owner: owner, secondsPerNote: 0.6) }
        if !audio.isPlaying { session.finishDemonstration(completed: false, at: hostTime()) }
    }

    private func tick() {
        guard session.isActive else { return }
        let now = hostTime()
        let playing = audio.isPlaying || audio.isPaused
        session.setAudioContext(capturing: audio.isCapturing, playbackBlocking: playing, at: now)
        if session.phase == .listening {
            if playing && audio.ownerID != owner { session.finishDemonstration(completed: false, at: now) }
            else if !playing { session.finishDemonstration(completed: true, at: now) }
        }
        session.update(at: now)
    }

    private func next() {
        session.next(at: hostTime())
        if session.phase == .awaitingDemonstration { demonstrate(strum: false) }
    }

    private func finish() {
        preparingTask?.cancel(); preparingTask = nil; isPreparing = false
        if audio.ownerID == owner { audio.stop() }
        session.stop()
    }
}

private enum ChordPracticeCollection: String, CaseIterable, Identifiable {
    case major, minor, both
    var id: String { rawValue }
    var title: String { self == .major ? "大和弦" : self == .minor ? "小和弦" : "大、小和弦混合" }
    var kinds: [ChordKind] { self == .major ? [.major] : self == .minor ? [.minor] : [.major, .minor] }
}
