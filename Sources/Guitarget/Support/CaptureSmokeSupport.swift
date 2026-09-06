import Foundation
import GuitarAudio

/// Integration probes wait for actual readiness before measuring capture.
@MainActor
func refreshCaptureDevices(_ audio: AudioService) async throws {
    guard await audio.refreshDevicesForCapture() else {
        throw NSError(domain: "GuitargetCaptureSmoke", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "音频设备刷新超时，未使用旧设备列表继续验收。"])
    }
}

@MainActor
func startSystemCaptureForSmoke(_ audio: AudioService) async throws {
    audio.startCapture()
    let deadline = ProcessInfo.processInfo.systemUptime + 15
    while audio.isStartingCapture && !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    guard audio.isCapturing, !Task.isCancelled else {
        let reason = audio.status
        audio.stopCapture()
        throw NSError(domain: "GuitargetCaptureSmoke", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "系统采集未就绪：" + reason])
    }
}
