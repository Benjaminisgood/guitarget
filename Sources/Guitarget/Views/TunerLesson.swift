import SwiftUI
import Combine
import GuitarCore
import GuitarAudio

struct TunerLesson: View {
    @ObservedObject var audio: AudioService
    @AppStorage("tuner.preset") private var presetID = TunerPreset.standard.rawValue
    @AppStorage("tuner.referenceA4") private var referenceA4 = 440.0
    @State private var mode = TunerMode.automaticString
    @State private var lockedString = 6
    @State private var engine = TunerEngine()
    @State private var showAudioSettings = false
    @State private var now = ProcessInfo.processInfo.systemUptime
    @State private var resumeInputAfter = 0.0
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private let playbackOwner = "独立调音器"

    private var configuration: TunerConfiguration {
        TunerConfiguration(mode: mode, preset: TunerPreset(rawValue: presetID) ?? .standard,
                           lockedString: lockedString, referenceA4: referenceA4)
    }
    private var referencePlaying: Bool { audio.ownerID == playbackOwner && (audio.isPlaying || audio.isPaused) }
    private var referenceMIDI: Int {
        if mode == .chromatic { return engine.reading?.target?.midi ?? 69 }
        return engine.reading?.target?.midi ?? configuration.stringTarget(lockedString)!.midi
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LearningHeader(eyebrow: "TUNER / SINGLE NOTE", title: "让每根弦，回到准音。",
                           subtitle: "先选调弦，再轻拨一根空弦。频率、目标与稳定性，一眼看清。")
            controls
            LearningCard(title: "实时音准", icon: "tuningfork") {
                TunerReadout(reading: engine.reading, waitingText: waitingText)
                TunerCentsMeter(cents: engine.reading?.cents, inTune: engine.reading?.isInTune == true)
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(targetDescription).font(.headline)
                        Text(targetFrequencyDescription).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(stabilityDescription).foregroundStyle(engine.reading?.isInTune == true ? Color.green : Color.secondary)
                        if let spread = engine.reading?.spreadCents {
                            Text(String(format: "近期波动 %.1f 音分", spread)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button {
                        let midi = referenceMIDI
                        engine.reset(); resumeInputAfter = .infinity
                        audio.previewTunerReference(midi: midi, a4: configuration.referenceA4, owner: playbackOwner)
                        // A failed output start must not leave input readings suspended forever.
                        if !referencePlaying { resumeInputAfter = ProcessInfo.processInfo.systemUptime + 0.4 }
                    } label: {
                        Label("播放 \(MusicTheory.noteName(midi: referenceMIDI)) 参考音", systemImage: "speaker.wave.2")
                    }.disabled(referencePlaying)
                    if referencePlaying { Button("停止参考音") { audio.stop() } }
                    Spacer()
                    Text(String(format: "A4 = %.1f Hz", configuration.referenceA4)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            stringTargets
            LearningCard(title: "近期音准与稳定性", icon: "waveform.path") {
                TunerHistoryChart(points: engine.history, now: now)
                HStack(alignment: .top) {
                    Text("最近 8 秒 · 纵轴 ±50 音分，超出部分显示在边缘").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("清空历史") { engine.reset() }.controlSize(.small)
                }
                Text("连续至少 4 次读数、持续至少 180 ms，且最近 400 ms 波动不超过 10 音分，显示为稳定；稳定且偏差在 ±5 音分内时显示调准。").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("目标弦是按频率匹配或由你锁定的参考，声音无法确定实际弹了哪根弦。调弦预设和 A4 只用于这里的调音与参考音，曲谱文档保持自身设置。").font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            referenceA4 = TunerConfiguration.validReference(referenceA4)
            engine.configure(configuration); receive(audio.pitchFrame)
        }
        .onChange(of: configuration) { _, value in
            if referencePlaying { audio.stop() }
            engine.configure(value)
        }
        .onReceive(audio.$pitchFrame) { receive($0) }
        .onChange(of: audio.isCapturing) { _, active in
            if !active { engine.reset() }
        }
        .onChange(of: referencePlaying) { _, playing in
            engine.reset()
            resumeInputAfter = playing ? .infinity : ProcessInfo.processInfo.systemUptime + 0.4
        }
        .onReceive(timer) { _ in
            now = ProcessInfo.processInfo.systemUptime
            engine.advance(now: now, captureActive: audio.isCapturing && !referencePlaying)
        }
        .onDisappear {
            if referencePlaying { audio.stop() }
            engine.reset()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Picker("调音模式", selection: $mode) {
                    ForEach(TunerMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 410)
                Spacer()
                Button { showAudioSettings.toggle() } label: { Label("声音来源", systemImage: "slider.horizontal.3") }
                    .popover(isPresented: $showAudioSettings) { AudioSettingsView(audio: audio).padding(22).frame(width: 520) }
            }
            HStack(spacing: 18) {
                Picker("调弦", selection: $presetID) {
                    ForEach(TunerPreset.allCases) { Text($0.title).tag($0.rawValue) }
                }.frame(width: 220)
                Stepper(value: $referenceA4, in: 400...480, step: 0.5) {
                    Text(String(format: "A4  %.1f Hz", configuration.referenceA4)).monospacedDigit()
                }.frame(width: 180)
                Button("恢复 440") { referenceA4 = 440 }.controlSize(.small).disabled(configuration.referenceA4 == 440)
                Spacer()
            }
            HStack(spacing: 10) {
                Circle().fill(audio.isCapturing ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                Text(audio.isCapturing ? "\(audio.source.title) · \(audio.status)" : audio.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 12)
                ProgressView(value: audio.isCapturing ? min(1, max(0, audio.inputLevel * 5)) : 0)
                    .frame(width: 90).tint(.green).accessibilityLabel("声音输入电平")
            }
        }
    }

    private var stringTargets: some View {
        LearningCard(title: "\(configuration.preset.title) · 空弦目标", icon: "guitars") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                ForEach((1...6).reversed(), id: \.self) { string in
                    let target = configuration.stringTarget(string)!
                    let selected = mode == .lockedString ? lockedString == string : engine.reading?.target?.string == string
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            lockedString = string; mode = .lockedString
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(string) 弦\(string == 6 ? " · 最粗" : string == 1 ? " · 最细" : "")").font(.caption).foregroundStyle(.secondary)
                                Text(target.name).font(.system(size: 28, weight: .semibold, design: .rounded))
                                Text(String(format: "%.2f Hz", target.frequency)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("锁定 \(string) 弦 \(target.name)")
                        Button {
                            engine.reset(); resumeInputAfter = .infinity
                            audio.previewTunerReference(midi: target.midi, a4: configuration.referenceA4, owner: playbackOwner)
                            if !referencePlaying { resumeInputAfter = ProcessInfo.processInfo.systemUptime + 0.4 }
                        } label: { Label("参考音", systemImage: "play.fill") }
                            .controlSize(.small).disabled(referencePlaying)
                            .accessibilityLabel("播放 \(string) 弦 \(target.name) 参考音")
                    }
                    .padding(12)
                    .background(selected ? Color.orange.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.orange : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
                }
            }
            Text(mode == .chromatic ? "色度模式匹配所有半音。点选上方空弦，可直接切换到锁定弦。" : "从 6 弦到 1 弦排列。点选空弦锁定目标；自动模式只匹配距离最近且在 ±250 音分内的空弦。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var waitingText: String {
        if referencePlaying { return "参考音播放中 · 读数已暂停" }
        if audio.isStartingCapture { return "正在启动声音采集" }
        if !audio.isCapturing { return "在“声音来源”中启用单音输入" }
        if now < resumeInputAfter { return "等待参考音衰减" }
        return audio.inputLevel > 0.004 ? "等待可靠的单音读数" : "轻拨一根弦，等待单音输入"
    }
    private var targetDescription: String {
        if let target = engine.reading?.target {
            if let string = target.string { return "\(mode == .lockedString ? "锁定" : "匹配")目标 · \(string) 弦 \(target.name)" }
            return "色度目标 · \(target.name)"
        }
        if mode == .lockedString, let target = configuration.stringTarget(lockedString) { return "锁定目标 · \(lockedString) 弦 \(target.name)" }
        if engine.reading != nil { return "超出空弦匹配范围 · 可手动锁定目标" }
        return mode == .chromatic ? "色度目标 · 等待单音" : "自动目标弦 · 等待单音"
    }
    private var targetFrequencyDescription: String {
        let target = engine.reading?.target ?? (mode == .lockedString ? configuration.stringTarget(lockedString) : nil)
        return target.map { String(format: "目标 %.2f Hz", $0.frequency) } ?? "目标频率随 A4 基准计算"
    }
    private var stabilityDescription: String {
        guard let reading = engine.reading else { return "暂无稳定性读数" }
        if reading.target == nil { return "尚未匹配目标" }
        if abs(reading.cents ?? 0) > 100 { return "偏差较大 · 请确认目标与八度" }
        if reading.isInTune { return "已调准 · 稳定在 ±5 音分内" }
        return reading.isStable ? "音高稳定 · 继续微调" : "观察音高稳定性…"
    }
    private func receive(_ frame: PitchFrame?) {
        let time = ProcessInfo.processInfo.systemUptime
        guard !referencePlaying, time >= resumeInputAfter else { engine.reset(); return }
        if let frame, frame.timestamp < resumeInputAfter { return }
        let observation = frame.map { PitchObservation(timestamp: $0.timestamp, frequency: $0.frequency, confidence: $0.confidence, rms: $0.rms) }
        engine.receive(observation, now: time, captureActive: audio.isCapturing)
    }
}
