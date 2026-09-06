import XCTest
@testable import GuitarAudio

@MainActor
final class PlaybackCoordinatorTests: XCTestCase {
    func testTransferPausesPreviousOutputBeforeCallerStartsNext() {
        let coordinator = PlaybackCoordinator()
        let score = UUID(), recording = UUID()
        var audible: Set<UUID> = []
        XCTAssertTrue(coordinator.acquire(token: score) {
            audible.remove(score)
            coordinator.release(token: score)
        })
        audible.insert(score)

        XCTAssertTrue(coordinator.acquire(token: recording) { audible.remove(recording) })
        XCTAssertTrue(audible.isEmpty)
        audible.insert(recording)
        XCTAssertEqual(audible, [recording])
        XCTAssertEqual(coordinator.activeToken, recording)
    }

    func testPausedOwnerCannotReleaseAnotherOutputAndResumeTakesItBack() {
        let coordinator = PlaybackCoordinator()
        let score = UUID(), recording = UUID()
        var scorePauses = 0, recordingPauses = 0
        coordinator.acquire(token: score) { scorePauses += 1 }
        coordinator.acquire(token: recording) { recordingPauses += 1 }
        coordinator.release(token: score)
        XCTAssertEqual(coordinator.activeToken, recording)
        XCTAssertEqual(scorePauses, 1)
        XCTAssertEqual(recordingPauses, 0)

        XCTAssertTrue(coordinator.acquire(token: score) { scorePauses += 1 })
        XCTAssertEqual(recordingPauses, 1)
        coordinator.release(token: score)
        XCTAssertNil(coordinator.activeToken)
    }

    func testRebuildingSameOutputDoesNotInterruptItself() {
        let coordinator = PlaybackCoordinator()
        let token = UUID()
        var pauses = 0
        coordinator.acquire(token: token) { pauses += 1 }
        coordinator.acquire(token: token) { pauses += 1 }
        XCTAssertEqual(pauses, 0)
        XCTAssertEqual(coordinator.activeToken, token)
    }

    func testSynchronousSubscriberCanSupersedeTransferWithoutTwoStarts() {
        let coordinator = PlaybackCoordinator()
        let first = UUID(), second = UUID(), third = UUID()
        var secondWasInterrupted = false
        coordinator.acquire(token: first) {
            coordinator.acquire(token: third) {}
        }
        let mayStartSecond = coordinator.acquire(token: second) { secondWasInterrupted = true }
        XCTAssertFalse(mayStartSecond)
        XCTAssertTrue(secondWasInterrupted)
        XCTAssertEqual(coordinator.activeToken, third)
    }
}
