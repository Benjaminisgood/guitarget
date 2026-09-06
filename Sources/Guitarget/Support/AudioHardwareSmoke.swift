import Foundation
import AVFoundation
import Combine
import CoreAudio
import GuitarCore
import GuitarAudio

/// Explicit native integration smoke test, invoked only by the development launch flag.
/// Runs the same AudioService as the app and launches/terminates only its own afplay child.
@MainActor
func runAudioHardwareSmoke(outputDirectory: URL) async -> [String: Any] {
    let audio = AudioService.shared
    let previousOutput = audio.outputDeviceID
    let previousSource = audio.source
    let previousProcess = audio.selectedProcessID
    let owner = "硬件自检-\(UUID().uuidString)"
    var child: Process?
    let collector = HardwareSmokeFrames(audio: audio)
    var result: [String: Any] = [
        "kind": "native-audio-hardware-smoke",
        "startedAt": ISO8601DateFormatter().string(from: Date()),
        "expectedReferenceHz": 440.0,
        "realGuitarTested": false,
        "note": "已知合成参考音的真实系统采集测试。窗口中心到 UI 交付时间不是声卡回环延迟；输出时钟推进不代表已由人耳确认听感。"
    ]
    defer {
        collector.finish()
        if let child, child.isRunning { child.terminate() }
        audio.stopCapture()
        if audio.ownerID == owner { audio.stop() }
        audio.setOutputDevice(previousOutput)
        audio.source = previousSource
        audio.selectedProcessID = previousProcess
    }
    do {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let diagnostics = try AudioDiagnostics.run(outputDirectory: outputDirectory)
        guard let referencePath = diagnostics["referenceA4"] as? String else {
            throw NSError(domain: "GuitargetHardwareSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "未生成 A4 参考音"])
        }
        let reference = outputDirectory.appendingPathComponent("reference-a4-long.wav")
        try Data(contentsOf: URL(fileURLWithPath: referencePath)).write(to: reference, options: .atomic)
        result["referenceFile"] = reference.path
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.2", reference.path]
        player.standardOutput = FileHandle.nullDevice
        player.standardError = FileHandle.nullDevice
        try player.run(); child = player
        result["ownedAfplayPID"] = player.processIdentifier
        audio.stop(); audio.stopCapture(); audio.source = .system; audio.selectedProcessID = nil
        await hardwareSmokeWait(seconds: 0.35)
        try await refreshCaptureDevices(audio)
        result["outputDevices"] = audio.outputDevices.map { ["id": $0.id, "name": $0.name, "channels": $0.channels] as [String: Any] }

        collector.begin()
        try await startSystemCaptureForSmoke(audio)
        await hardwareSmokeMeasure(seconds: 2.2, audio: audio, collector: collector)
        var mix = collector.report(audio: audio)
        let mixPassed = referenceMatched(mix) && audio.isCapturing
        mix["passed"] = mixPassed
        result["systemMix"] = mix

        audio.stopCapture(); try await refreshCaptureDevices(audio)
        let processFound = audio.processes.contains { $0.id == player.processIdentifier }
        result["ownedAfplayListed"] = processFound
        audio.selectedProcessID = player.processIdentifier
        collector.begin()
        try await startSystemCaptureForSmoke(audio)
        await hardwareSmokeMeasure(seconds: 2.2, audio: audio, collector: collector)
        var specific = collector.report(audio: audio)
        let specificPassed = processFound && referenceMatched(specific) && audio.isCapturing
        specific["passed"] = specificPassed
        specific["selectedProcessID"] = player.processIdentifier
        result["specificProcess"] = specific

        // This child belongs to this invocation; never terminate a pre-existing process.
        let runningBeforeTermination = player.isRunning
        if player.isRunning { player.terminate() }
        await hardwareSmokeWait(seconds: 1.6)
        try await refreshCaptureDevices(audio)
        let exited = !player.isRunning
        let exitStoppedCapture = exited && !audio.isCapturing && audio.status.contains("已退出")
        result["sourceProcessExit"] = [
            "wasRunning": runningBeforeTermination,
            "ownedChildExited": exited,
            "captureStopped": !audio.isCapturing,
            "status": audio.status,
            "passed": runningBeforeTermination && exitStoppedCapture
        ]

        audio.stopCapture(); audio.selectedProcessID = nil
        try await startSystemCaptureForSmoke(audio)
        await hardwareSmokeWait(seconds: 0.35)
        collector.begin()
        audio.preview(notes: [GuitarNote(string: 1, fret: 5)], owner: owner)
        await hardwareSmokeMeasure(seconds: 2.2, audio: audio, collector: collector)
        var exclusion = collector.report(audio: audio)
        let ownOutputRendered = audio.currentTick > 0 && audio.ownerID == owner
        let exclusionPassed = audio.isCapturing && ownOutputRendered && collector.frames.isEmpty && collector.maximumRMS < 0.004
        exclusion["ownOutputClockAdvanced"] = ownOutputRendered
        exclusion["externalOwnedPlayerStopped"] = exited
        exclusion["passed"] = exclusionPassed
        exclusion["interpretation"] = exclusionPassed ? "自身 A4 试听输出时未捕获可识别音高或显著电平。" : "未满足隔离条件：检查其他 App 是否仍在输出声音，并检查本次帧与电平证据。"
        result["selfExclusion"] = exclusion
        audio.stopCapture(); audio.stop()

        try await refreshCaptureDevices(audio)
        let builtIn = audio.outputDevices.first { $0.transportType == kAudioDeviceTransportTypeBuiltIn }
        var outputCheck: [String: Any] = ["previousSelection": previousOutput, "physicalAudibilityMeasured": false]
        var outputPassed = false
        if let builtIn {
            audio.setOutputDevice(builtIn.id)
            let configured = audio.outputDeviceID == builtIn.id
            audio.preview(notes: [GuitarNote(string: 1, fret: 5, velocity: 0.45)], owner: owner)
            await hardwareSmokeWait(seconds: 0.45)
            let renderAdvanced = audio.currentTick > 0 && audio.isPlaying
            outputCheck["builtInDevice"] = builtIn.name
            outputCheck["builtInDeviceID"] = builtIn.id
            outputCheck["configured"] = configured
            outputCheck["renderClockAdvanced"] = renderAdvanced
            outputCheck["statusOnBuiltIn"] = audio.status
            audio.stop()
            audio.setOutputDevice(previousOutput)
            let restored = audio.outputDeviceID == previousOutput
            audio.preview(notes: [GuitarNote(string: 1, fret: 5, velocity: 0.45)], owner: owner)
            await hardwareSmokeWait(seconds: 0.45)
            let restoredRenderAdvanced = audio.currentTick > 0 && audio.isPlaying
            outputCheck["restoredSelection"] = restored
            outputCheck["restoredRenderClockAdvanced"] = restoredRenderAdvanced
            outputCheck["statusAfterRestore"] = audio.status
            outputPassed = configured && renderAdvanced && restored && restoredRenderAdvanced
            audio.stop()
        } else { outputCheck["reason"] = "没有可用的内置输出设备，无法执行本项真实设备切换。" }
        outputCheck["passed"] = outputPassed
        result["outputDeviceSwitch"] = outputCheck
        result["passed"] = mixPassed && specificPassed && exitStoppedCapture && exclusionPassed && outputPassed
        result["finishedAt"] = ISO8601DateFormatter().string(from: Date())
    } catch {
        result["passed"] = false
        result["error"] = error.localizedDescription
        result["status"] = audio.status
    }
    do {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputDirectory.appendingPathComponent("audio-hardware-smoke.json"), options: .atomic)
    } catch { result["reportWriteError"] = error.localizedDescription }
    return result
}

@MainActor
private final class HardwareSmokeFrames {
    var frames: [PitchFrame] = []
    private var received: [Double] = []
    var maximumRMS = 0.0
    private var startedAt = 0.0
    private var recording = false
    private var subscription: AnyCancellable?
    init(audio: AudioService) {
        subscription = audio.pitchFrames.sink { [weak self] frame in
            guard let self, self.recording else { return }
            self.frames.append(frame)
            self.received.append(AVAudioTime.seconds(forHostTime: mach_absolute_time()))
            self.maximumRMS = max(self.maximumRMS, frame.rms)
        }
    }
    func begin() {
        frames.removeAll(keepingCapacity: true); received.removeAll(keepingCapacity: true)
        maximumRMS = 0; recording = true
        startedAt = AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }
    func observe(level: Double) { maximumRMS = max(maximumRMS, level) }
    func finish() { recording = false; subscription?.cancel() }
    func report(audio: AudioService) -> [String: Any] {
        let frequencies = frames.map(\.frequency).sorted()
        let lags = zip(frames, received).map { ($1 - $0.timestamp) * 1000 }
        var result: [String: Any] = [
            "startedAtHostTime": startedAt,
            "finishedAtHostTime": AVAudioTime.seconds(forHostTime: mach_absolute_time()),
            "pitchedFrameCount": frames.count,
            "maximumRMS": maximumRMS,
            "captureRunning": audio.isCapturing,
            "status": audio.status,
            "captureDiagnostics": audio.captureDiagnostics,
            "frames": zip(frames, received).map { frame, delivered -> [String: Any] in
                var row: [String: Any] = ["windowCenterHostTime": frame.timestamp, "deliveredAtHostTime": delivered, "frequencyHz": frame.frequency, "midi": frame.midi, "cents": frame.cents, "confidence": frame.confidence, "rms": frame.rms, "stable": frame.isStable]
                if let onset = frame.onsetTimestamp { row["onsetHostTime"] = onset }
                return row
            }
        ]
        if !frequencies.isEmpty {
            let median = frequencies[frequencies.count / 2]
            result["medianFrequencyHz"] = median
            result["medianCentsFrom440"] = 1200 * log2(median / 440)
            result["minimumFrequencyHz"] = frequencies.first!
            result["maximumFrequencyHz"] = frequencies.last!
            result["meanWindowCenterToDeliveryMilliseconds"] = lags.reduce(0, +) / Double(lags.count)
            result["maximumWindowCenterToDeliveryMilliseconds"] = lags.max()!
        }
        recording = false
        return result
    }
}

@MainActor
private func hardwareSmokeMeasure(seconds: Double, audio: AudioService, collector: HardwareSmokeFrames) async {
    let end = ProcessInfo.processInfo.systemUptime + seconds
    while ProcessInfo.processInfo.systemUptime < end && !Task.isCancelled {
        collector.observe(level: audio.inputLevel)
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    collector.observe(level: audio.inputLevel)
}

private func referenceMatched(_ report: [String: Any]) -> Bool {
    guard let count = report["pitchedFrameCount"] as? Int, count >= 5,
          let cents = report["medianCentsFrom440"] as? Double else { return false }
    return abs(cents) <= 5
}

private func hardwareSmokeWait(seconds: Double) async {
    let end = ProcessInfo.processInfo.systemUptime + seconds
    while ProcessInfo.processInfo.systemUptime < end && !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
}
