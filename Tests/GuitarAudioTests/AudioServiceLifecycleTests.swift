import XCTest
import Combine
@testable import GuitarAudio

@MainActor final class AudioServiceLifecycleTests: XCTestCase {
    private func makeCapturingService() -> AudioService {
        let service = AudioService(startRuntime: false)
        service.source = .input
        service.markCaptureStarted()
        return service
    }
    private func frame(_ frequency: Double, at timestamp: Double) -> PitchFrame {
        PitchFrame(timestamp: timestamp, frequency: frequency, midi: frequency == 440 ? 69 : 45,
                   cents: 0, confidence: 0.99, rms: 0.2, isStable: true, onsetTimestamp: timestamp - 0.2)
    }
    func testQueuedOldPitchAndSilenceCannotCrossCaptureRestart() async {
        let service = makeCapturingService()
        let oldGeneration = service.captureGeneration
        let oldFrame = frame(440, at: 1)
        let currentFrame = frame(110, at: 2)
        var scored: [PitchFrame] = []
        let subscription = service.pitchFrames.sink { scored.append($0) }
        // These tasks cannot run until this main-actor turn yields, matching analysis
        // results already queued when the user stops and immediately starts capture.
        let queuedPitch = Task { @MainActor in service.receiveCaptureFrame(oldFrame, rms: 0.7, generation: oldGeneration) }
        let queuedSilence = Task { @MainActor in service.receiveCaptureFrame(nil, rms: 0, generation: oldGeneration) }
        service.stopCapture()
        service.markCaptureStarted()
        service.receiveCaptureFrame(currentFrame, rms: 0.2, generation: service.captureGeneration)
        await queuedPitch.value
        await queuedSilence.value
        XCTAssertEqual(scored, [currentFrame])
        XCTAssertEqual(service.pitchFrame, currentFrame)
        XCTAssertEqual(service.inputLevel, 0.2)
        XCTAssertTrue(service.isCapturing)
        withExtendedLifetime(subscription) {}
        service.stopCapture()
    }
    func testQueuedPitchRemainsDiscardedAfterCaptureStops() async {
        let service = makeCapturingService()
        let generation = service.captureGeneration
        let oldFrame = frame(440, at: 1)
        var scored: [PitchFrame] = []
        let subscription = service.pitchFrames.sink { scored.append($0) }
        let queued = Task { @MainActor in service.receiveCaptureFrame(oldFrame, rms: 0.3, generation: generation) }
        service.stopCapture()
        await queued.value
        XCTAssertTrue(scored.isEmpty)
        XCTAssertNil(service.pitchFrame)
        XCTAssertEqual(service.inputLevel, 0)
        XCTAssertFalse(service.isCapturing)
        withExtendedLifetime(subscription) {}
    }
    func testScoringSubscriberStoppingCaptureCannotRestoreOldUIFrame() {
        let service = makeCapturingService()
        let subscription = service.pitchFrames.sink { _ in service.stopCapture() }
        service.receiveCaptureFrame(frame(440, at: 1), rms: 0.3, generation: service.captureGeneration)
        XCTAssertFalse(service.isCapturing)
        XCTAssertNil(service.pitchFrame)
        XCTAssertEqual(service.inputLevel, 0)
        withExtendedLifetime(subscription) {}
    }
    func testRunningInputConfigurationChangeStopsCaptureWithSpecificReason() {
        for (running, matchingFormat) in [(false, true), (true, false)] {
            let service = makeCapturingService()
            service.receiveCaptureFrame(frame(440, at: 1), rms: 0.3, generation: service.captureGeneration)
            service.handleRunningInputConfigurationChange(generation: service.captureGeneration,
                                                         engineIsRunning: running, formatMatches: matchingFormat)
            XCTAssertFalse(service.isCapturing)
            XCTAssertFalse(service.isStartingCapture)
            XCTAssertNil(service.pitchFrame)
            XCTAssertEqual(service.inputLevel, 0)
            XCTAssertTrue(service.status.contains("输入设备配置或采样率发生变化"))
        }
    }
    func testStaleAndCompletedStartupNotificationsDoNotStopCurrentCapture() {
        let service = makeCapturingService()
        let oldGeneration = service.captureGeneration
        service.stopCapture()
        service.markCaptureStarted()
        service.handleRunningInputConfigurationChange(generation: oldGeneration, engineIsRunning: false, formatMatches: false)
        XCTAssertTrue(service.isCapturing)
        // A notification queued during negotiation can arrive after healthy startup.
        service.handleRunningInputConfigurationChange(generation: service.captureGeneration, engineIsRunning: true, formatMatches: true)
        XCTAssertTrue(service.isCapturing)
        service.stopCapture()
    }
}
