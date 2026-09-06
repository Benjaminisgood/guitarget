import Foundation
import CoreAudio
import Synchronization

/// HAL requests may block inside the audio server. Never synchronously wait for this queue.
enum AudioHardwareWork {
    static let queue = DispatchQueue(label: "com.guitarget.hardware", qos: .userInitiated)
}

final class CaptureCancellation: @unchecked Sendable {
    private let cancelled = Atomic<Bool>(false)
    var isCancelled: Bool { cancelled.load(ordering: .acquiring) }
    func cancel() { cancelled.store(true, ordering: .releasing) }
    func check() throws { if isCancelled { throw CancellationError() } }
}

protocol SystemTapBackend: AnyObject {
    func start(process: AudioProcess?) throws
    func stop()
    var diagnostics: [String: Any] { get }
    var clockConfigurationChanged: Bool { get }
}

/// Backend resource operations stay on the serial HAL queue, including late cleanup.
final class SystemTapSession: @unchecked Sendable {
    typealias Factory = (CaptureRing, CaptureCancellation) -> SystemTapBackend
    private let queue: DispatchQueue
    private let ring: CaptureRing
    private let cancellation = CaptureCancellation()
    private let factory: Factory
    private var backend: SystemTapBackend?
    init(ring: CaptureRing, queue: DispatchQueue = AudioHardwareWork.queue,
         factory: @escaping Factory = { ProcessTapCapture(ring: $0, cancellation: $1) }) {
        self.ring = ring; self.queue = queue; self.factory = factory
    }
    deinit {
        let remaining = backend
        backend = nil
        // Keep the backend alive until background stop clears its HAL handles. A later
        // ARC release can then call its empty stop() without a HAL operation on the UI thread.
        if let remaining { queue.async { remaining.stop() } }
    }
    func start(process: AudioProcess?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async { [self] in
            guard !cancellation.isCancelled else { completion(.failure(CancellationError())); return }
            let capture = factory(ring, cancellation)
            backend = capture
            do {
                try capture.start(process: process)
                try cancellation.check()
                completion(.success(capture.diagnostics))
            } catch {
                capture.stop(); backend = nil
                completion(.failure(error))
            }
        }
    }
    func cancel() {
        cancellation.cancel()
        queue.async { [self] in backend?.stop(); backend = nil }
    }
    func inspect(completion: @escaping ([String: Any], Bool) -> Void) {
        queue.async { [self] in
            guard !cancellation.isCancelled, let backend else { return }
            let changed = backend.clockConfigurationChanged
            guard !cancellation.isCancelled else { return }
            completion(backend.diagnostics, changed)
        }
    }
}

struct AudioHardwareSnapshot: Sendable {
    var inputs: [AudioDevice]
    var outputs: [AudioDevice]
    var processes: [AudioProcess]
    var defaultInput: UInt32
    var defaultOutput: UInt32
    static func read() -> AudioHardwareSnapshot {
        AudioHardwareSnapshot(inputs: audioDevices(input: true), outputs: audioDevices(input: false), processes: audioProcesses(),
                              defaultInput: audioScalar(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice, initial: UInt32(0)),
                              defaultOutput: audioScalar(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, initial: UInt32(0)))
    }
}
