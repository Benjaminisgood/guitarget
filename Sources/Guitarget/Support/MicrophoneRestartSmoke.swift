import Foundation
import CoreAudio
import GuitarAudio

/// Development-only callback check. Silence is valid; no pitch accuracy is claimed.
@MainActor
func runMicrophoneRestartSmoke(outputDirectory: URL) async -> [String: Any] {
    let audio = AudioService.shared
    let previousSource = audio.source, previousDevice = audio.inputDeviceID
    let previousChannel = audio.inputChannel
    audio.stop(); audio.stopCapture()
    let refreshed = await audio.refreshDevicesForCapture()
    let builtIn = refreshed ? audio.inputDevices.first { $0.transportType == kAudioDeviceTransportTypeBuiltIn } : nil
    var result: [String: Any] = ["kind": "microphone-restart-smoke", "startedAt": ISO8601DateFormatter().string(from: Date()), "realGuitarAccuracyMeasured": false]
    var runs: [[String: Any]] = []
    if let device = builtIn {
        audio.source = .input; audio.inputDeviceID = device.id; audio.inputChannel = 0
        result["device"] = device.name
        for index in 1...3 {
            audio.startCapture()
            var startupStates: [[String: Any]] = []
            let startupDeadline = ProcessInfo.processInfo.systemUptime + 60
            while audio.isStartingCapture && ProcessInfo.processInfo.systemUptime < startupDeadline {
                startupStates.append(audio.captureDiagnostics)
                try? await Task.sleep(for: .milliseconds(100))
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 7
            while ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            var run = audio.captureDiagnostics
            run["iteration"] = index
            run["status"] = audio.status
            run["startupStates"] = startupStates
            // Each capture generation owns a fresh ring; this count starts at zero.
            run["newSamples"] = run["capturedSamples"] as? Int ?? 0
            // The service's watchdog stops any capture that has not written samples for 4s.
            run["passed"] = audio.isCapturing && (run["newSamples"] as? Int ?? 0) > 0
            runs.append(run)
            audio.stopCapture()
        }
    } else { result["error"] = refreshed ? "未找到内置麦克风" : "音频设备刷新超时" }
    audio.stopCapture()
    audio.source = previousSource; audio.inputDeviceID = previousDevice; audio.inputChannel = previousChannel
    result["runs"] = runs
    result["passed"] = runs.count == 3 && runs.allSatisfy { $0["passed"] as? Bool == true }
    result["finishedAt"] = ISO8601DateFormatter().string(from: Date())
    do {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDirectory.appendingPathComponent("microphone-restart-smoke.json"), options: .atomic)
    } catch { result["reportWriteError"] = error.localizedDescription }
    return result
}
