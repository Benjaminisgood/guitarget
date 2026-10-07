import SwiftUI
import GuitarAudio
import GuitarCore

/// Single-note tuner: the same GuitarCore TunerEngine the macOS app drives, fed by
/// AudioService's microphone capture path.
struct TunerTab: View {
    @EnvironmentObject private var audio: AudioService
    @AppStorage("ios.tuner.preset") private var presetID = TunerPreset.standard.rawValue
    @AppStorage("ios.tuner.referenceA4") private var referenceA4 = 440.0
    @State private var mode = TunerMode.automaticString
    @State private var lockedString = 6
    @State private var engine = TunerEngine()
    @State private var now = ProcessInfo.processInfo.systemUptime
    @State private var resumeInputAfter = 0.0
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private let playbackOwner = "iOS 调音器"

    private var preset: TunerPreset { TunerPreset(rawValue: presetID) ?? .standard }
    private var configuration: TunerConfiguration {
        TunerConfiguration(mode: mode, preset: preset, lockedString: lockedString, referenceA4: referenceA4)
    }
    private var referencePlaying: Bool { audio.ownerID == playbackOwner && (audio.isPlaying || audio.isPaused) }
    private var referenceMIDI: Int {
        if mode == .chromatic { return engine.reading?.target?.midi ?? 69 }
        return engine.reading?.target?.midi ?? configuration.stringTarget(lockedString)?.midi ?? 69
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    IOSHeader(eyebrow: "TUNER / SINGLE NOTE", title: "让每根弦，回到准音。",
                              subtitle: "点“开始采集”，再轻拨一根空弦。")
                    IOSCard(title: "实时音准", icon: "tuningfork") {
                        readout
                        CentsMeter(cents: engine.reading?.cents, inTune: engine.reading?.isInTune == true)
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(targetDescription).font(.subheadline.weight(.medium))
                                Text(frequencyDescription).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(stabilityDescription)
                                .font(.caption)
                                .foregroundStyle(engine.reading?.isInTune == true ? Color.green : Color.secondary)
                        }
                        referenceControls
                    }
                    IOSCard(title: "\(preset.title) · 空弦目标", icon: "guitars") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                            ForEach((1...6).reversed(), id: \.self) { string in stringCard(string) }
                        }
                        Text(preset.lowToHighNames).font(.caption).foregroundStyle(.secondary)
                    }
                    IOSCard(title: "调弦设置", icon: "slider.horizontal.3") {
                        Picker("调音模式", selection: $mode) {
                            ForEach(TunerMode.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        Picker("调弦", selection: $presetID) {
                            ForEach(TunerPreset.allCases) { Text($0.title).tag($0.rawValue) }
                        }.pickerStyle(.menu)
                        HStack {
                            Text(String(format: "A4  %.1f Hz", configuration.referenceA4)).monospacedDigit()
                            Spacer()
                            Stepper("", value: $referenceA4, in: 400...480, step: 0.5).labelsHidden()
                            Button("440") { referenceA4 = 440 }.font(.caption).disabled(configuration.referenceA4 == 440)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("调音器")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            referenceA4 = TunerConfiguration.validReference(referenceA4)
            engine.configure(configuration)
            receive(audio.pitchFrame)
        }
        .onChange(of: configuration) { _, value in
            if referencePlaying { audio.stop() }
            engine.configure(value)
        }
        .onReceive(audio.$pitchFrame) { receive($0) }
        .onChange(of: audio.isCapturing) { _, active in if !active { engine.reset() } }
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

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(engine.reading?.target?.name ?? MusicTheory.noteName(midi: engine.reading?.detectedMIDI ?? 69))
                .font(.system(size: 52, weight: .semibold, design: .rounded))
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.reading.map { String(format: "%.1f Hz", $0.frequency) } ?? "—")
                    .font(.callout).monospacedDigit()
                Text(engine.reading?.cents.map { String(format: "%+.0f 音分", $0) } ?? "等待单音")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(engine.reading?.isInTune == true ? Color.green : Color.secondary)
            }
            Spacer()
        }
    }

    private var referenceControls: some View {
        HStack(spacing: 12) {
            Button {
                let midi = referenceMIDI
                engine.reset(); resumeInputAfter = .infinity
                audio.previewTunerReference(midi: midi, a4: configuration.referenceA4, owner: playbackOwner)
                if !referencePlaying { resumeInputAfter = ProcessInfo.processInfo.systemUptime + 0.4 }
            } label: {
                Label("参考音 \(MusicTheory.noteName(midi: referenceMIDI))", systemImage: "speaker.wave.2")
            }
            .buttonStyle(.bordered)
            .disabled(referencePlaying)
            if referencePlaying { Button("停止") { audio.stop() }.buttonStyle(.bordered) }
            Spacer()
        }
        .font(.callout)
    }

    private func stringCard(_ string: Int) -> some View {
        let target = configuration.stringTarget(string)
        let selected = mode == .lockedString ? lockedString == string : engine.reading?.target?.string == string
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                lockedString = string; mode = .lockedString
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(string) 弦").font(.caption2).foregroundStyle(.secondary)
                    Text(target?.name ?? "—").font(.title2.weight(.semibold)).foregroundStyle(.primary)
                    Text(target.map { String(format: "%.1f Hz", $0.frequency) } ?? "—")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button {
                guard let target else { return }
                engine.reset(); resumeInputAfter = .infinity
                audio.previewTunerReference(midi: target.midi, a4: configuration.referenceA4, owner: playbackOwner)
                if !referencePlaying { resumeInputAfter = ProcessInfo.processInfo.systemUptime + 0.4 }
            } label: { Label("试听", systemImage: "play.fill").font(.caption2) }
            .disabled(target == nil || referencePlaying)
        }
        .padding(10)
        .background(selected ? Color.orange.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.orange : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
    }

    private var targetDescription: String {
        if let target = engine.reading?.target {
            if let string = target.string { return "\(mode == .lockedString ? "锁定" : "匹配")目标 · \(string) 弦 \(target.name)" }
            return "色度目标 · \(target.name)"
        }
        if mode == .lockedString, let target = configuration.stringTarget(lockedString) { return "锁定目标 · \(lockedString) 弦 \(target.name)" }
        return mode == .chromatic ? "色度目标 · 等待单音" : "自动目标弦 · 等待单音"
    }
    private var frequencyDescription: String {
        let target = engine.reading?.target ?? (mode == .lockedString ? configuration.stringTarget(lockedString) : nil)
        return target.map { String(format: "目标 %.2f Hz", $0.frequency) } ?? "目标频率随 A4 基准计算"
    }
    private var stabilityDescription: String {
        guard let reading = engine.reading else { return audio.isCapturing ? "等待可靠单音" : "未开始采集" }
        if reading.target == nil { return "尚未匹配目标" }
        if abs(reading.cents ?? 0) > 100 { return "偏差较大 · 确认八度" }
        if reading.isInTune { return "已调准 ±5 音分内" }
        return reading.isStable ? "音高稳定 · 继续微调" : "观察稳定性…"
    }
    private func receive(_ frame: PitchFrame?) {
        let time = ProcessInfo.processInfo.systemUptime
        guard !referencePlaying, time >= resumeInputAfter else { engine.reset(); return }
        if let frame, frame.timestamp < resumeInputAfter { return }
        let observation = frame.map { PitchObservation(timestamp: $0.timestamp, frequency: $0.frequency, confidence: $0.confidence, rms: $0.rms) }
        engine.receive(observation, now: time, captureActive: audio.isCapturing)
    }
}
