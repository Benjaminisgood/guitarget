import XCTest
import Combine
import GuitarCore
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
    private func chord(_ label: PitchClass, at timestamp: Double) -> ChordFrame {
        ChordFrame(timestamp: timestamp, chord: .chord(ChordDefinition(root: label, kind: .major), bass: nil), confidence: 0.98, fit: 0.97, heldDuration: 0.3)
    }
    func testChordFramesFollowTheSameGenerationRulesAndPublishChangesImmediately() async {
        let service = makeCapturingService()
        let oldGeneration = service.captureGeneration
        var judged: [ChordFrame] = []
        let subscription = service.chordFrames.sink { judged.append($0) }
        let queued = Task { @MainActor in service.receiveChordFrame(self.chord(.a, at: 1), generation: oldGeneration) }
        service.stopCapture()
        service.markCaptureStarted()
        let first = chord(.c, at: 2)
        service.receiveChordFrame(first, generation: service.captureGeneration)
        // Same symbol 20 ms later: scored, but the presentation copy is throttled.
        var held = first; held.timestamp = 2.02; held.heldDuration = 0.32
        service.receiveChordFrame(held, generation: service.captureGeneration)
        XCTAssertEqual(service.chordFrame, first)
        // A new symbol is shown at once, and silence clears the display without a scored frame.
        let next = chord(.g, at: 2.04)
        service.receiveChordFrame(next, generation: service.captureGeneration)
        XCTAssertEqual(service.chordFrame, next)
        service.receiveChordFrame(nil, generation: service.captureGeneration)
        XCTAssertNil(service.chordFrame)
        await queued.value
        XCTAssertEqual(judged, [first, held, next])
        service.stopCapture()
        XCTAssertNil(service.chordFrame)
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
