import Foundation
import SwiftUI
import AppKit
import AVFoundation
import Combine
import CoreAudio
import GuitarAudio

/// Development-only guided acquisition. Presents a panel and waits for an explicit Start click.
/// The function never plays a reference sound or computes a supposed true-guitar accuracy score.
@MainActor
func runGuitarCapture(outputDirectory: URL) async -> [String: Any] {
    let session = GuitarCaptureSession(outputDirectory: outputDirectory)
    return await session.presentAndWait()
}

private struct GuitarCapturePhase: Codable, Sendable {
    var id: String
    var title: String
    var instruction: String
    var kind: String
    var string: Int?
    var expectedMIDI: Int?
    var expectedNote: String?
    var durationSeconds: Double
    var transitionSeconds: Double
    var plannedStartHostTime: Double?
    var plannedEndHostTime: Double?
    var evaluationStartHostTime: Double?
    var actualStartHostTime: Double?
    var actualEndHostTime: Double?
}

private struct GuitarCaptureFrame: Codable, Sendable {
    var timestamp: Double
    var windowCenterHostTime: Double
    var onsetHostTime: Double?
    var deliveredAtHostTime: Double
    var frequencyHz: Double
    var midi: Int
    var cents: Double
    var confidence: Double
    var stable: Bool
    var rms: Double
    var phaseID: String?
    var inEvaluationWindow: Bool
}

private struct GuitarCaptureLevel: Codable, Sendable {
    var hostTime: Double
    var rms: Double
    var phaseID: String?
}

private struct GuitarCaptureDevice: Codable, Sendable {
    var deviceID: UInt32
    var name: String
    var channels: Int
    var selectedChannelIndex: Int
    var nominalSampleRate: Double
    var selectionReason: String
    var sampleRateMeaning = "CoreAudio 输入设备名义采样率；不是物理输入延迟。"
}

private struct GuitarCaptureProgress: Codable, Sendable {
    var schemaVersion = 1
    var kind = "guided-real-guitar-capture"
    var sessionID: String
    var status: String
    var statusText: String
    var createdAt: String
    var startedAt: String?
    var finishedAt: String?
    var startedAtHostTime: Double?
    var finishedAtHostTime: Double?
    var elapsedSeconds: Double
    var plannedDurationSeconds: Double
    var currentPhaseID: String?
    var pitchFrameCount: Int
    var inputLevelRecordCount: Int
    var device: GuitarCaptureDevice?
    var phases: [GuitarCapturePhase]
    var sessionDirectory: String
    var framesPath: String
    var manifestPath: String
    var dataWrittenAt: String
    var note = "真实吉他采集记录。expectedMIDI 是提示的目标音，不是独立测量的真实音高；可据阶段计算目标音识别比例，不能称为真琴音准准确率。windowCenterHostTime 到 deliveredAtHostTime 是软件交付间隔，不是物理输入延迟。frames 仅含分析器输出的有效音高帧；静音和无可信音高时的电平另存 inputLevels。"
}

private struct GuitarCaptureFramesFile: Codable, Sendable {
    var schemaVersion = 1
    var sessionID: String
    var frames: [GuitarCaptureFrame]
    var inputLevels: [GuitarCaptureLevel]
}

@MainActor
private final class GuitarCaptureSession: NSObject, ObservableObject, NSWindowDelegate {
    @Published var heading = "准备真琴采集"
    @Published var instruction = "准备好吉他后点击“开始”。全程不会播放参考音。"
    @Published var target = "—"
    @Published var remaining = 100
    @Published var progress = 0.0
    @Published var isStarting = false
    @Published var isRecording = false
    @Published var isFinished = false
    @Published var latestPitch = "等待开始"
    @Published var inputLevel = 0.0
    @Published var pluckCue = false
    @Published var statusLine = "内置麦克风 · 约 100 秒 · 可随时停止并保存"

    private let audio = AudioService.shared
    private let outputDirectory: URL
    private let directory: URL
    private let sessionID = UUID().uuidString
    private let createdAt = ISO8601DateFormatter().string(from: Date())
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<[String: Any], Never>?
    private var subscription: AnyCancellable?
    private var task: Task<Void, Never>?
    private var stopRequested = false
    private var closeWhenFinished = false
    private var savingFinished = false
    private var frames: [GuitarCaptureFrame] = []
    private var levels: [GuitarCaptureLevel] = []
    private var phases = GuitarCaptureSession.makePhases()
    private var device: GuitarCaptureDevice?
    private var state = "waiting-for-user"
    private var startedAt: String?
    private var finishedAt: String?
    private var startHost: Double?
    private var finishHost: Double?
    private var currentIndex: Int?
    private var finalError: String?
    private var previousSource: CaptureSource = .off
    private var previousInputID: UInt32 = 0
    private var previousChannel = 0

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"; formatter.locale = Locale(identifier: "en_US_POSIX")
        directory = outputDirectory.appendingPathComponent("guitar-capture-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))", isDirectory: true)
        super.init()
    }
    static func makePhases() -> [GuitarCapturePhase] {
        var phases = [GuitarCapturePhase(id: "prepare", title: "准备", instruction: "调整坐姿，轻触其他弦保持安静。", kind: "preparation", durationSeconds: 8, transitionSeconds: 8)]
        for (string, midi, name) in [(6,40,"E2"),(5,45,"A2"),(4,50,"D3"),(3,55,"G3"),(2,59,"B3"),(1,64,"E4")] {
            phases.append(GuitarCapturePhase(id: "open-string-\(string)", title: "第 \(string) 弦 · \(name) 空弦", instruction: "每 2 秒轻拨一次。用另一只手轻触其余弦。", kind: "repeated-open-string", string: string, expectedMIDI: midi, expectedNote: name, durationSeconds: 12, transitionSeconds: 2))
        }
        phases.append(GuitarCapturePhase(id: "low-e-sustain", title: "第 6 弦 · E2 持续音", instruction: "提示时只拨一次，然后保持，让声音自然延续。", kind: "single-pluck-sustain", string: 6, expectedMIDI: 40, expectedNote: "E2", durationSeconds: 10, transitionSeconds: 2))
        phases.append(GuitarCapturePhase(id: "low-e-repeated", title: "第 6 弦 · E2 重复拨弦", instruction: "每 2 秒轻拨一次，检验同音重新起音。", kind: "repeated-same-note", string: 6, expectedMIDI: 40, expectedNote: "E2", durationSeconds: 10, transitionSeconds: 0))
        return phases
    }
    func presentAndWait() async -> [String: Any] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 530), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "真琴采集 · 开发验收"
            panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: GuitarCapturePanel(session: self))
            panel.delegate = self; self.panel = panel
            panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            Task { try? await self.persist() }
        }
    }
    func start() {
        guard !isStarting, !isRecording, !isFinished else { return }
        task = Task { await record() }
    }
    func requestStop(closeAfter: Bool = false) {
        closeWhenFinished = closeWhenFinished || closeAfter
        stopRequested = true
        if isFinished { closePanel(); return }
        if !isStarting && !isRecording { Task { await finish(status: "cancelled", text: "未开始采集。") } }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { requestStop(closeAfter: true); return false }

    private func record() async {
        isStarting = true; state = "starting-input"; heading = "正在打开麦克风"
        instruction = "如 macOS 请求权限，请允许麦克风访问。准备倒计时会在采集启动后开始。"
        previousSource = audio.source; previousInputID = audio.inputDeviceID; previousChannel = audio.inputChannel
        audio.stop(); audio.stopCapture()
        guard await audio.refreshDevicesForCapture(), !stopRequested else {
            await finish(status: stopRequested ? "cancelled" : "input-failed",
                         text: stopRequested ? "已取消采集。" : "音频设备刷新超时，请稍后重试。")
            return
        }
        let builtIn = audio.inputDevices.first { $0.transportType == kAudioDeviceTransportTypeBuiltIn }
        let selectedID = builtIn?.id ?? audio.defaultInputDeviceID
        let selected = audio.inputDevices.first { $0.id == selectedID }
        device = GuitarCaptureDevice(deviceID: selectedID, name: selected?.name ?? "系统默认输入", channels: selected?.channels ?? 1, selectedChannelIndex: 0, nominalSampleRate: selected?.nominalSampleRate ?? 0, selectionReason: builtIn != nil ? "内置麦克风（用户指定的真琴验收来源）" : "没有列出的内置麦克风，使用系统默认输入")
        audio.source = .input; audio.inputDeviceID = selectedID; audio.inputChannel = 0
        subscription = audio.pitchFrames.sink { [weak self] frame in self?.receive(frame) }
        audio.startCapture()
        var lastSave = -Double.infinity
        let permissionDeadline = guitarCaptureHostTime() + 60
        while !audio.isCapturing && !stopRequested && guitarCaptureHostTime() < permissionDeadline {
            statusLine = audio.status
            let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
            if authorization == .denied || authorization == .restricted { break }
            // TCC may become authorized before its completion reaches MainActor.
            if authorization == .authorized && !audio.isStartingCapture { break }
            if guitarCaptureHostTime() - lastSave >= 1 {
                do { try await persist(); lastSave = guitarCaptureHostTime() }
                catch { finalError = error.localizedDescription; break }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard audio.isCapturing, !stopRequested, finalError == nil else {
            await finish(status: stopRequested ? "cancelled" : "input-failed", text: finalError ?? audio.status); return
        }
        let start = guitarCaptureHostTime(); startHost = start; startedAt = ISO8601DateFormatter().string(from: Date())
        var cursor = start
        for index in phases.indices {
            phases[index].plannedStartHostTime = cursor
            phases[index].evaluationStartHostTime = cursor + phases[index].transitionSeconds
            cursor += phases[index].durationSeconds
            phases[index].plannedEndHostTime = cursor
        }
        isStarting = false; isRecording = true; state = "recording"; lastSave = -Double.infinity
        do {
            while !stopRequested && !Task.isCancelled {
                let now = guitarCaptureHostTime()
                guard audio.isCapturing, audio.source == .input, audio.inputDeviceID == selectedID else {
                    await finish(status: "input-stopped", text: "声音输入已停止或来源发生变化；已保存现有记录。"); return
                }
                guard let index = phases.firstIndex(where: { now >= $0.plannedStartHostTime! && now < $0.plannedEndHostTime! }) else { break }
                if currentIndex != index {
                    if let previous = currentIndex { phases[previous].actualEndHostTime = now }
                    phases[index].actualStartHostTime = now; currentIndex = index
                }
                let phase = phases[index]
                let phaseElapsed = now - phase.plannedStartHostTime!
                let inTransition = phaseElapsed < phase.transitionSeconds
                heading = phase.title
                target = phase.expectedNote ?? "准备"
                remaining = max(0, Int(ceil(phase.plannedEndHostTime! - now)))
                progress = min(1, (now - start) / 100)
                if phase.kind == "preparation" {
                    instruction = phase.instruction; pluckCue = false
                } else if inTransition {
                    instruction = "换到目标弦，暂不拨弦。换弦准备还剩 \(Int(ceil(phase.transitionSeconds - phaseElapsed))) 秒。"
                    pluckCue = false
                } else {
                    instruction = phase.instruction
                    let activeTime = phaseElapsed - phase.transitionSeconds
                    pluckCue = phase.kind == "single-pluck-sustain" ? activeTime < 0.45 : activeTime.truncatingRemainder(dividingBy: 2) < 0.45
                }
                inputLevel = audio.inputLevel
                latestPitch = audio.pitchFrame.map { String(format: "%@%d · %.2f Hz · %+.1f 音分", $0.noteName, $0.octave, $0.frequency, $0.cents) } ?? "等待可信单音 · 电平仍持续记录"
                levels.append(GuitarCaptureLevel(hostTime: now, rms: audio.inputLevel, phaseID: phase.id))
                statusLine = "\(device?.name ?? "麦克风") · 已记录 \(frames.count) 个有效音高帧"
                if now - lastSave >= 1 {
                    device?.nominalSampleRate = audio.inputDevices.first { $0.id == selectedID }?.nominalSampleRate ?? 0
                    try await persist(); lastSave = now
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await finish(status: stopRequested || Task.isCancelled ? "stopped-by-user" : "completed", text: stopRequested ? "已停止并保存现有记录。" : "采集完成。原始记录与阶段标签已保存，等待复核。")
        } catch { finalError = error.localizedDescription; await finish(status: "save-failed", text: "保存失败：\(error.localizedDescription)") }
    }
    private func receive(_ frame: PitchFrame) {
        guard isStarting || isRecording else { return }
        let phase = phases.first { phase in
            guard let start = phase.plannedStartHostTime, let end = phase.plannedEndHostTime else { return false }
            return frame.timestamp >= start && frame.timestamp < end
        }
        let evaluation = phase?.expectedMIDI != nil && frame.timestamp >= (phase?.evaluationStartHostTime ?? .infinity)
        frames.append(GuitarCaptureFrame(timestamp: frame.timestamp, windowCenterHostTime: frame.timestamp, onsetHostTime: frame.onsetTimestamp, deliveredAtHostTime: guitarCaptureHostTime(), frequencyHz: frame.frequency, midi: frame.midi, cents: frame.cents, confidence: frame.confidence, stable: frame.isStable, rms: frame.rms, phaseID: phase?.id, inEvaluationWindow: evaluation))
    }
    private func finish(status: String, text: String) async {
        guard !savingFinished else { return }
        savingFinished = true
        finishHost = guitarCaptureHostTime(); finishedAt = ISO8601DateFormatter().string(from: Date())
        if let index = currentIndex { phases[index].actualEndHostTime = finishHost }
        subscription?.cancel(); subscription = nil
        if isStarting || isRecording {
            if audio.source == .input && audio.inputDeviceID == device?.deviceID { audio.stopCapture() }
            audio.source = previousSource; audio.inputDeviceID = previousInputID; audio.inputChannel = previousChannel
        }
        isStarting = false; isRecording = false; isFinished = true; pluckCue = false; state = status
        heading = status == "completed" ? "采集完成" : "采集已结束"; instruction = text; statusLine = text
        if status == "completed" { progress = 1; remaining = 0 }
        do { try await persist() }
        catch { finalError = error.localizedDescription; statusLine = "写入记录失败：\(error.localizedDescription)" }
        var result: [String: Any] = ["kind": "guided-real-guitar-capture", "sessionID": sessionID, "status": state, "recordedPitchFrames": frames.count, "sessionDirectory": directory.path, "framesPath": directory.appendingPathComponent("frames.json").path, "manifestPath": directory.appendingPathComponent("session.json").path, "latestProgressPath": outputDirectory.appendingPathComponent("guitar-capture-progress.json").path, "scientificAcceptanceClaimed": false]
        if let finalError { result["error"] = finalError }
        continuation?.resume(returning: result); continuation = nil
        if closeWhenFinished { closePanel() }
    }
    private func snapshot() -> GuitarCaptureProgress {
        let now = finishHost ?? guitarCaptureHostTime()
        return GuitarCaptureProgress(sessionID: sessionID, status: state, statusText: statusLine, createdAt: createdAt, startedAt: startedAt, finishedAt: finishedAt, startedAtHostTime: startHost, finishedAtHostTime: finishHost, elapsedSeconds: startHost.map { max(0, now - $0) } ?? 0, plannedDurationSeconds: 100, currentPhaseID: currentIndex.map { phases[$0].id }, pitchFrameCount: frames.count, inputLevelRecordCount: levels.count, device: device, phases: phases, sessionDirectory: directory.path, framesPath: directory.appendingPathComponent("frames.json").path, manifestPath: directory.appendingPathComponent("session.json").path, dataWrittenAt: ISO8601DateFormatter().string(from: Date()))
    }
    private func persist() async throws {
        let progress = snapshot()
        let records = GuitarCaptureFramesFile(sessionID: sessionID, frames: frames, inputLevels: levels)
        let directory = directory, root = outputDirectory
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let frameData = try encoder.encode(records)
            let progressData = try encoder.encode(progress)
            // Write data first; a published progress snapshot never points beyond saved frames.
            try frameData.write(to: directory.appendingPathComponent("frames.json"), options: .atomic)
            try progressData.write(to: directory.appendingPathComponent("progress.json"), options: .atomic)
            try progressData.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
            try progressData.write(to: root.appendingPathComponent("guitar-capture-progress.json"), options: .atomic)
        }.value
    }
    private func closePanel() {
        panel?.delegate = nil; panel?.orderOut(nil); panel?.contentView = nil; panel = nil
    }
}

private struct GuitarCapturePanel: View {
    @ObservedObject var session: GuitarCaptureSession
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("真琴采集", systemImage: "guitars").font(.title2.bold())
                Spacer()
                Text("全程无参考音播放").font(.caption).foregroundStyle(.secondary)
            }
            Text(session.heading).font(.title3.bold())
            HStack(alignment: .firstTextBaseline) {
                Text(session.target).font(.system(size: 58, weight: .bold, design: .rounded))
                Spacer()
                Text("\(session.remaining)").font(.system(size: 44, weight: .medium, design: .monospaced))
                Text("秒").foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Circle().fill(session.pluckCue ? Color.orange : Color.secondary.opacity(0.2)).frame(width: 16, height: 16)
                Text(session.pluckCue ? "现在轻拨" : session.instruction).font(.body).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 58, alignment: .top)
            ProgressView(value: session.progress).tint(.orange)
            Divider()
            Text(session.latestPitch).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            ProgressView(value: min(1, session.inputLevel * 5)).tint(.green)
            Text(session.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Text("每根弦前 2 秒用于换弦，不计入目标识别阶段。尽量让其他弦和其他 App 保持安静。结果用于复核目标音识别表现，不等同于测量真实音准或物理延迟。").font(.caption).foregroundStyle(.secondary)
            HStack {
                if session.isFinished {
                    Button("关闭") { session.requestStop(closeAfter: true) }.buttonStyle(.borderedProminent)
                } else if session.isStarting || session.isRecording {
                    Button("停止并保存") { session.requestStop() }.buttonStyle(.bordered)
                } else {
                    Button("开始") { session.start() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    Button("取消") { session.requestStop(closeAfter: true) }
                }
                Spacer()
            }
        }.padding(24).frame(width: 540, height: 530)
    }
}

private func guitarCaptureHostTime() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
