import XCTest
import Combine
import Synchronization
@testable import GuitarAudio

private final class FakeSystemTap: SystemTapBackend {
    let onStart: () -> Void
    let onStop: () -> Void
    init(onStart: @escaping () -> Void, onStop: @escaping () -> Void) { self.onStart = onStart; self.onStop = onStop }
    func start(process: AudioProcess?) throws { onStart() }
    func stop() { onStop() }
    var diagnostics: [String: Any] { ["fakeBackend": true] }
    var clockConfigurationChanged: Bool { false }
}

private final class CaptureRings: @unchecked Sendable {
    private let lock = NSLock()
    private var rings: [CaptureRing] = []
    func append(_ ring: CaptureRing) -> Int { lock.lock(); defer { lock.unlock() }; rings.append(ring); return rings.count - 1 }
    func snapshot() -> [CaptureRing] { lock.lock(); defer { lock.unlock() }; return rings }
}

@MainActor final class SystemTapSessionTests: XCTestCase {
    func testBlockedStartCanBeCancelledAndRetriedWithAnIndependentRing() async {
        let queue = DispatchQueue(label: "test.blocked-system-tap")
        let firstEntered = expectation(description: "First HAL call entered")
        let firstStopped = expectation(description: "Cancelled backend cleaned up off main")
        let secondEntered = expectation(description: "Second HAL call entered")
        let secondStopped = expectation(description: "Second backend cleaned up off main")
        let releaseFirst = DispatchSemaphore(value: 0), releaseSecond = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal(); releaseSecond.signal() }
        let rings = CaptureRings()
        let first = FakeSystemTap(onStart: {
            XCTAssertFalse(Thread.isMainThread); firstEntered.fulfill()
            XCTAssertEqual(releaseFirst.wait(timeout: .now() + 3), .success)
        }, onStop: { XCTAssertFalse(Thread.isMainThread); firstStopped.fulfill() })
        let second = FakeSystemTap(onStart: {
            XCTAssertFalse(Thread.isMainThread); secondEntered.fulfill()
            XCTAssertEqual(releaseSecond.wait(timeout: .now() + 3), .success)
        }, onStop: { XCTAssertFalse(Thread.isMainThread); secondStopped.fulfill() })
        let service = AudioService(startRuntime: false, hardwareQueue: queue, systemTapFactory: { ring, _ in
            rings.append(ring) == 0 ? first : second
        })
        service.source = .system
        service.startCapture()
        await fulfillment(of: [firstEntered], timeout: 1)
        XCTAssertTrue(service.isStartingCapture)
        XCTAssertFalse(service.isCapturing)
        // This stays responsive even though the first worker cannot return yet.
        service.stopCapture()
        XCTAssertFalse(service.isStartingCapture)
        service.startCapture()
        XCTAssertTrue(service.isStartingCapture)
        releaseFirst.signal()
        await fulfillment(of: [firstStopped, secondEntered], timeout: 1)
        XCTAssertTrue(service.isStartingCapture)
        XCTAssertFalse(service.isCapturing)
        let ready = expectation(description: "Only the current session becomes ready")
        let subscription = service.$isCapturing.sink { if $0 { ready.fulfill() } }
        releaseSecond.signal()
        await fulfillment(of: [ready], timeout: 1)
        let capturedRings = rings.snapshot()
        XCTAssertEqual(capturedRings.count, 2)
        XCTAssertFalse(capturedRings[0] === capturedRings[1])
        // Model an old IO callback which had passed its cancellation guard already.
        let oldSamples = [Float](repeating: 0.2, count: 512)
        oldSamples.withUnsafeBufferPointer {
            capturedRings[0].write($0.baseAddress!, count: $0.count, stride: 1, rate: 48000, time: 1)
        }
        XCTAssertEqual(service.captureDiagnostics["capturedSamples"] as? Int, 0)
        XCTAssertTrue(service.isCapturing)
        service.stopCapture()
        await fulfillment(of: [secondStopped], timeout: 1)
        withExtendedLifetime(subscription) {}
    }
    func testSystemStartTimeoutCancelsWithoutWaitingForHALToReturn() async {
        let queue = DispatchQueue(label: "test.system-tap-timeout")
        let entered = expectation(description: "HAL entered")
        let stopped = expectation(description: "Late HAL return cleaned up")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let backend = FakeSystemTap(onStart: {
            entered.fulfill(); XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
        }, onStop: { XCTAssertFalse(Thread.isMainThread); stopped.fulfill() })
        let service = AudioService(startRuntime: false, hardwareQueue: queue, systemTapFactory: { _, _ in backend }, systemStartTimeoutSeconds: 0.04)
        service.source = .system
        service.startCapture()
        let timedOut = expectation(description: "UI leaves starting while HAL is blocked")
        let subscription = service.$isStartingCapture.sink { if !$0 { timedOut.fulfill() } }
        await fulfillment(of: [entered, timedOut], timeout: 1)
        XCTAssertFalse(service.isCapturing)
        XCTAssertFalse(service.isStartingCapture)
        XCTAssertTrue(service.status.contains("启动超时"))
        release.signal()
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertFalse(service.isCapturing)
        withExtendedLifetime(subscription) {}
    }
    func testBlockedHardwareReadTimesOutWaitersWithoutAccumulatingReads() async {
        let queue = DispatchQueue(label: "test.hardware-refresh-timeout")
        let entered = expectation(description: "Hardware read entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let count = Atomic<Int>(0)
        let device = AudioDevice(id: 91, name: "Input snapshot", channels: 2, nominalSampleRate: 44100, transportType: 7)
        let service = AudioService(startRuntime: false, hardwareQueue: queue, snapshotProvider: {
            _ = count.wrappingAdd(1, ordering: .relaxed)
            XCTAssertFalse(Thread.isMainThread); entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            return AudioHardwareSnapshot(inputs: [device], outputs: [], processes: [], defaultInput: 91, defaultOutput: 0)
        })
        service.refreshDevices()
        await fulfillment(of: [entered], timeout: 1)
        let first = Task { @MainActor in await service.refreshDevicesForCapture(timeout: 0.025) }
        let second = Task { @MainActor in await service.refreshDevicesForCapture(timeout: 0.035) }
        for _ in 0..<20 { service.refreshDevices() }
        let firstResult = await first.value, secondResult = await second.value
        XCTAssertFalse(firstResult); XCTAssertFalse(secondResult)
        for _ in 0..<20 { service.refreshDevices() }
        XCTAssertEqual(count.load(ordering: .relaxed), 1)
        XCTAssertTrue(service.inputDevices.isEmpty)
        release.signal()
        let refreshed = await service.refreshDevicesForCapture(timeout: 1)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(service.inputDevices, [device])
        XCTAssertEqual(service.defaultInputDeviceID, 91)
        XCTAssertEqual(count.load(ordering: .relaxed), 1)
    }
}
