import Foundation
import AVFoundation
import Combine
import CoreAudio
import GuitarAudio
import GuitarCore

/// Tests two simultaneously audible processes; runs only through the explicit development flag.
@MainActor
func runSystemIsolationSmoke(outputDirectory: URL, playerExecutable: URL) async -> [String: Any] {
    let audio = AudioService.shared
    let previousSource = audio.source, previousProcess = audio.selectedProcessID
    let previousOutput = audio.outputDeviceID
    let owner = "系统隔离验证-\(UUID().uuidString)"
    var children: [Process] = []
    var frames: [PitchFrame] = []
    var collecting = false
    let subscription = audio.pitchFrames.sink { if collecting { frames.append($0) } }
    var result: [String: Any] = ["kind": "two-process-system-isolation", "startedAt": ISO8601DateFormatter().string(from: Date()), "realGuitarTested": false, "physicalOutputMeasured": false]
    defer {
        subscription.cancel()
        for child in children where child.isRunning { child.terminate() }
        audio.stopCapture()
        if audio.ownerID == owner { audio.stop() }
        audio.setOutputDevice(previousOutput)
        audio.source = previousSource; audio.selectedProcessID = previousProcess
    }
    do {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let a4 = outputDirectory.appendingPathComponent("source-a-440.wav")
        let other = outputDirectory.appendingPathComponent("source-b-697.wav")
        try isolationTone(440, to: a4)
        try isolationTone(697, to: other)
        for (executable, arguments) in [(URL(fileURLWithPath: "/usr/bin/afplay"), [a4.path]), (playerExecutable, [other.path])] {
            let child = Process()
            child.executableURL = executable; child.arguments = arguments
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); children.append(child)
        }
        audio.stop(); audio.stopCapture(); audio.source = .system
        await isolationWait(0.6)
        try await refreshCaptureDevices(audio)
        var checks: [[String: Any]] = []
        for index in 0..<2 {
            let child = children[index]
            let expected = index == 0 ? 440.0 : 697.0
            guard let process = audio.processes.first(where: { $0.id == child.processIdentifier }) else {
                throw NSError(domain: "GuitargetIsolation", code: 1, userInfo: [NSLocalizedDescriptionKey: "参考进程未登记到 CoreAudio"])
            }
            audio.stopCapture(); audio.selectedProcessID = process.id
            try await startSystemCaptureForSmoke(audio)
            // Discard startup windows before measuring the selected source.
            await isolationWait(0.4)
            frames = []; collecting = true
            await isolationWait(2)
            collecting = false
            let values = frames.map(\.frequency).sorted()
            let median = values.isEmpty ? 0 : values[values.count / 2]
            let cents = median > 0 ? 1200 * log2(median / expected) : nil
            let inRange = frames.filter { abs(1200 * log2($0.frequency / expected)) < 5 }.count
            let bothRunning = children.allSatisfy(\.isRunning)
            var check: [String: Any] = ["selectedPID": process.id, "selectedBundleID": process.bundleID, "expectedHz": expected, "bothSourcesRunning": bothRunning, "pitchedFrames": frames.count, "framesWithin5Cents": inRange, "medianHz": median, "diagnostics": audio.captureDiagnostics]
            if let cents { check["medianCentsFromReference"] = cents }
            check["passed"] = audio.isCapturing && bothRunning && values.count >= 10 && inRange == values.count
            checks.append(check)
        }
        result["isolationChecks"] = checks
        audio.stopCapture()
        // A live tap must continue emitting quiet buffers after its external players stop.
        for child in children where child.isRunning { child.terminate() }
        await isolationWait(0.5)
        audio.selectedProcessID = nil; try await startSystemCaptureForSmoke(audio)
        await isolationWait(0.4)
        frames = []; collecting = true
        audio.preview(notes: [GuitarNote(string: 1, fret: 5)], owner: owner)
        var maximumRMS = 0.0
        let until = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < until {
            maximumRMS = max(maximumRMS, audio.inputLevel)
            await isolationWait(0.025)
        }
        collecting = false
        let selfExcluded = audio.isCapturing && audio.currentTick > 0 && frames.isEmpty && maximumRMS < 0.004
        result["selfExclusion"] = ["passed": selfExcluded, "pitchedFrames": frames.count, "maximumRMS": maximumRMS, "outputClockAdvanced": audio.currentTick > 0, "diagnostics": audio.captureDiagnostics]
        audio.stopCapture(); audio.stop(); try await refreshCaptureDevices(audio)
        let outputs = audio.outputDevices.filter { $0.name.contains("扬声器") }
        var deviceChecks: [[String: Any]] = []
        for device in outputs.prefix(1) {
            audio.setOutputDevice(device.id)
            audio.preview(notes: [GuitarNote(string: 1, fret: 5, velocity: 0.3)], owner: owner)
            await isolationWait(0.35)
            let actual = audio.activeOutputDeviceID
            deviceChecks.append(["requestedDeviceID": device.id, "actualDeviceID": actual ?? 0, "deviceName": device.name, "outputClockAdvanced": audio.currentTick > 0, "passed": actual == device.id && audio.currentTick > 0])
            audio.stop()
        }
        result["outputDeviceReadback"] = deviceChecks
        audio.preview(notes: [GuitarNote(string: 1, fret: 5, velocity: 0.2)], owner: owner)
        await isolationWait(0.2)
        let wasPlaying = audio.isPlaying
        let previousDevice = audio.outputDeviceID
        audio.setOutputDevice(UInt32.max)
        let failurePaused = wasPlaying && !audio.isPlaying && audio.isPaused && audio.outputDeviceID == previousDevice
        result["invalidOutputDevice"] = ["passed": failurePaused, "isPlaying": audio.isPlaying, "isPaused": audio.isPaused, "status": audio.status]
        audio.setOutputDevice(previousDevice)
        audio.resume()
        let resumeTick = audio.currentTick
        await isolationWait(0.2)
        let failureRecovered = audio.isPlaying && audio.currentTick > resumeTick
        result["outputFailureRecovery"] = ["passed": failureRecovered, "clockAdvanced": audio.currentTick > resumeTick]
        audio.stop()
        result["passed"] = checks.count == 2 && checks.allSatisfy { $0["passed"] as? Bool == true } && selfExcluded && !deviceChecks.isEmpty && deviceChecks.allSatisfy { $0["passed"] as? Bool == true } && failurePaused && failureRecovered
    } catch { result["passed"] = false; result["error"] = error.localizedDescription; result["status"] = audio.status }
    result["finishedAt"] = ISO8601DateFormatter().string(from: Date())
    do {
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDirectory.appendingPathComponent("system-isolation-smoke.json"), options: .atomic)
    } catch { result["writeError"] = error.localizedDescription }
    return result
}

private func isolationWait(_ seconds: Double) async {
    try? await Task.sleep(for: .seconds(seconds))
}

private func isolationTone(_ frequency: Double, to url: URL) throws {
    let rate = 48000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let count = Int(rate * 30)
    for start in stride(from: 0, to: count, by: 2048) {
        let size = min(2048, count - start)
        buffer.frameLength = AVAudioFrameCount(size)
        for i in 0..<size {
            let time = Double(start + i) / rate
            let fade = min(1, time / 0.02, (30 - time) / 0.02)
            buffer.floatChannelData![0][i] = Float(0.08 * fade * sin(2 * .pi * frequency * time))
        }
        try file.write(from: buffer)
    }
}
