import Foundation
import Combine
import AVFoundation
import CoreAudio
import AudioToolbox
import GuitarCore

private final class PlaybackContext: @unchecked Sendable { var renderer: ScoreRenderer? }

private final class CaptureAnalyzer: @unchecked Sendable {
    let ring = CaptureRing()
    let queue = DispatchQueue(label: "com.guitarget.pitch", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var tracker = PitchTracker()
    private var onset = OnsetDetector()
    private var rolling: [Float] = []
    private var sinceAnalysis = 0
    private var lastRate = 0.0
    var deliver: ((PitchFrame?, Double, Int) -> Void)?
    func start(generation: Int) {
        stop()
        queue.sync { tracker = PitchTracker(); onset = OnsetDetector(); rolling.removeAll(keepingCapacity: true); sinceAnalysis = 0; lastRate = 0; ring.clear() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(12), leeway: .milliseconds(2))
        // Each timer retains its own generation, including a callback already in flight
        // when stop/restart occurs. Never label an old result with the new session ID.
        timer.setEventHandler { [weak self] in self?.process(generation: generation) }
        self.timer = timer; timer.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
    private func process(generation: Int) {
        guard let (samples, start) = ring.read(maximum: 8192) else { return }
        let rate = ring.sampleRate.load(ordering: .relaxed)
        if lastRate != rate { rolling.removeAll(keepingCapacity: true); tracker = PitchTracker(); onset = OnsetDetector(); lastRate = rate }
        for offset in stride(from: 0, to: samples.count, by: 128) {
            _ = onset.process(samples[offset..<min(offset + 128, samples.count)], sampleRate: rate, startTime: start + Double(offset) / rate)
        }
        rolling.append(contentsOf: samples); sinceAnalysis += samples.count
        let windowSize = rate >= 40000 ? 4096 : 2048
        if rolling.count > windowSize { rolling.removeFirst(rolling.count - windowSize) }
        guard rolling.count == windowSize, sinceAnalysis >= Int(rate * 0.025) else { return }
        sinceAnalysis = 0
        let end = start + Double(samples.count) / rate
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        // Low-pass and decimate before YIN to keep analysis off the real-time callback inexpensive.
        let analysis: [Float]
        let analysisRate: Double
        if rate >= 40000 {
            analysis = stride(from: 0, to: rolling.count - 1, by: 2).map { (rolling[$0] + rolling[$0 + 1]) * 0.5 }
            analysisRate = rate / 2
        } else { analysis = rolling; analysisRate = rate }
        let frame = tracker.analyze(analysis, sampleRate: analysisRate, timestamp: end - Double(windowSize) / rate / 2, onsetTimestamp: onset.onsetTimestamp)
        deliver?(frame, rms, generation)
    }
}

@MainActor public final class AudioService: ObservableObject {
    public static let shared = AudioService()
    /// Every analyzed non-silent frame, at analysis cadence; scoring must subscribe here.
    public let pitchFrames = PassthroughSubject<PitchFrame, Never>()
    @Published public private(set) var pitchFrame: PitchFrame?
    @Published public private(set) var inputLevel = 0.0
    @Published public private(set) var status = "音频就绪 · 采集已关闭"
    @Published public private(set) var inputDevices: [AudioDevice] = []
    @Published public private(set) var outputDevices: [AudioDevice] = []
    @Published public private(set) var processes: [AudioProcess] = []
    @Published public private(set) var defaultInputDeviceID: UInt32 = 0
    public private(set) var defaultOutputDeviceID: UInt32 = 0
    @Published public var source: CaptureSource = .off { didSet { if oldValue != source { stopCapture() } } }
    @Published public var inputDeviceID: UInt32 = 0 { didSet { if oldValue != inputDeviceID && (isCapturing || isStartingCapture) { stopCapture() } } }
    @Published public var outputDeviceID: UInt32 = 0
    @Published public var inputChannel = 0 { didSet { if oldValue != inputChannel && (isCapturing || isStartingCapture) && source == .input { stopCapture() } } }
    @Published public var selectedProcessID: Int32? { didSet { if oldValue != selectedProcessID && (isCapturing || isStartingCapture) && source == .system { stopCapture() } } }
    @Published public private(set) var isCapturing = false
    @Published public private(set) var isStartingCapture = false
    @Published public private(set) var ownerID: String?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isPaused = false
    @Published public private(set) var isCountingIn = false
    @Published public private(set) var currentTick = 0
    @Published public private(set) var transportStartHostTime: Double?
    @Published public var speed = 1.0 { didSet { if oldValue != speed { rebuildPlayback() } } }
    @Published public var loopRange: Range<Int>? { didSet { if oldValue != loopRange { rebuildPlayback() } } }
    @Published public var metronomeEnabled = false { didSet { if oldValue != metronomeEnabled { rebuildPlayback() } } }
    @Published public var countInEnabled = false
    @Published public var mutedVoices: Set<ScoreVoice> = [] { didSet { if oldValue != mutedVoices { rebuildPlayback() } } }
    public var captureDiagnostics: [String: Any] {
        if processTap != nil {
            return systemCaptureDiagnostics.merging(["source": source.rawValue, "isCapturing": isCapturing,
                "isStartingCapture": isStartingCapture, "capturedSamples": analyzer.ring.writeIndex.load(ordering: .relaxed)]) { _, new in new }
        }
        var result: [String: Any] = [
            "source": source.rawValue, "isCapturing": isCapturing, "isStartingCapture": isStartingCapture,
            "inputDeviceID": activeInputDevice, "requestedInputDeviceID": inputDeviceID,
            "inputChannel": inputChannel, "engineRunning": inputEngine?.isRunning ?? false,
            "capturedSamples": analyzer.ring.writeIndex.load(ordering: .relaxed)
        ]
        if let node = inputEngine?.inputNode {
            let hardware = node.inputFormat(forBus: 0), client = node.outputFormat(forBus: 0)
            result["hardwareFormat"] = ["sampleRate": hardware.sampleRate, "channels": Int(hardware.channelCount)]
            result["clientFormat"] = ["sampleRate": client.sampleRate, "channels": Int(client.channelCount)]
            result["deviceSampleRate"] = audioScalar(activeInputDevice, selector: kAudioDevicePropertyNominalSampleRate, initial: 0.0)
        }
        return result
    }
    /// Read back the device actually configured in the output AudioUnit.
    public var activeOutputDeviceID: UInt32? {
        guard let unit = outputEngine.outputNode.audioUnit else { return nil }
        var device: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr else { return nil }
        return device
    }
    public var selectedInputChannelCount: Int {
        let id = inputDeviceID == 0 ? defaultInputDeviceID : inputDeviceID
        return max(1, inputDevices.first(where: { $0.id == id })?.channels ?? 1)
    }
    public var inputLatency: Double {
        guard let node = inputEngine?.inputNode else { return 0 }
        return node.presentationLatency
    }
    private let outputEngine = AVAudioEngine()
    private let playbackToken = UUID()
    private let playbackCoordinator: PlaybackCoordinator
    private var inputEngine: AVAudioEngine?
    private var inputConfigurationObserver: NSObjectProtocol?
    private var inputStartTimeout: Timer?
    private var inputTapInstalled = false
    private var inputCaptureFormat: AVAudioFormat?
    private let playback = PlaybackContext()
    private var analyzer = CaptureAnalyzer()
    private var processTap: SystemTapSession?
    private var systemCaptureDiagnostics: [String: Any] = [:]
    private var systemStartTimeout: Task<Void, Never>?
    private var systemInspectionPending = false
    private let hardwareQueue: DispatchQueue
    private let snapshotProvider: () -> AudioHardwareSnapshot
    private let systemTapFactory: SystemTapSession.Factory
    private let systemStartTimeoutSeconds: TimeInterval
    private var hardwareReadPending = false
    private var hardwareWaiters: [UUID: (CheckedContinuation<Bool, Never>, Task<Void, Never>)] = [:]
    private var sourceNode: AVAudioSourceNode?
    private var updateTimer: Timer?
    private var monitorCounter = 0
    private(set) var captureGeneration = 0
    private var lastPitchUIUpdate = 0.0
    private var captureStartedAt = 0.0
    private var lastCaptureCount = 0
    private var lastDefaultOutput: AudioObjectID = 0
    private var activeInputDevice: AudioObjectID = 0
    private var captureIdleChecks = 0
    private var playingScore: GuitarScore?
    private var accompanimentOptions: AccompanimentPlaybackOptions?
    private let sampleRate = 48000.0
    private convenience init() { self.init(startRuntime: true) }
    // Lifecycle tests omit the hardware graph and device-monitoring timer.
    init(startRuntime: Bool, hardwareQueue: DispatchQueue = AudioHardwareWork.queue,
         snapshotProvider: @escaping () -> AudioHardwareSnapshot = AudioHardwareSnapshot.read,
         systemTapFactory: @escaping SystemTapSession.Factory = { ProcessTapCapture(ring: $0, cancellation: $1) },
         systemStartTimeoutSeconds: TimeInterval = 10,
         playbackCoordinator: PlaybackCoordinator? = nil) {
        self.hardwareQueue = hardwareQueue; self.snapshotProvider = snapshotProvider; self.systemTapFactory = systemTapFactory
        self.playbackCoordinator = playbackCoordinator ?? .shared
        self.systemStartTimeoutSeconds = systemStartTimeoutSeconds.isFinite ? max(0.001, min(30, systemStartTimeoutSeconds)) : 10
        configureAnalyzerDelivery()
        guard startRuntime else { return }
        let context = playback
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let node = AVAudioSourceNode(format: format) { _, timestamp, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = buffers.first, let raw = first.mData else { return noErr }
            let pointer = raw.assumingMemoryBound(to: Float.self)
            if let renderer = context.renderer {
                if renderer.hostAnchor.load(ordering: .relaxed) == -Double.infinity {
                    let host = AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime)
                    let anchor = host - Double(renderer.position.load(ordering: .relaxed)) / renderer.sampleRate
                    renderer.hostAnchor.store(anchor, ordering: .releasing)
                }
                renderer.render(into: pointer, frames: Int(frameCount))
            } else { pointer.update(repeating: 0, count: Int(frameCount)) }
            // The source format is mono. AVAudioEngine handles output channel conversion.
            return noErr
        }
        sourceNode = node
        outputEngine.attach(node); outputEngine.connect(node, to: outputEngine.mainMixerNode, format: format)
        outputEngine.mainMixerNode.outputVolume = 0.82
        refreshDevices()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }
    private func configureAnalyzerDelivery() {
        analyzer.deliver = { [weak self] frame, rms, generation in
            Task { @MainActor in self?.receiveCaptureFrame(frame, rms: rms, generation: generation) }
        }
    }
    func receiveCaptureFrame(_ frame: PitchFrame?, rms: Double, generation: Int) {
        guard isCapturing, generation == captureGeneration else { return }
        if let frame { pitchFrames.send(frame) }
        // A synchronous scoring subscriber can stop or restart capture during send().
        guard isCapturing, generation == captureGeneration else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // ObservableObject invalidation is presentation-only. Never throttle the scoring stream.
        let becameSilent = frame == nil && pitchFrame != nil
        if becameSilent || now - lastPitchUIUpdate >= 0.1 {
            if pitchFrame != frame { pitchFrame = frame }
            if abs(inputLevel - rms) > 0.000001 { inputLevel = rms }
            lastPitchUIUpdate = now
        }
    }
    public func refreshDevices() {
        guard !hardwareReadPending else { return }
        hardwareReadPending = true
        let read = snapshotProvider
        hardwareQueue.async { [weak self] in
            let snapshot = read()
            Task { @MainActor in self?.receiveHardwareSnapshot(snapshot) }
        }
    }
    /// True means a newly completed hardware read was published; false means it did not
    /// finish within the bound. A blocked HAL read never blocks the actor or creates retries.
    public func refreshDevicesForCapture(timeout: TimeInterval = 3) async -> Bool {
        let id = UUID()
        let seconds = timeout.isFinite ? max(0.001, min(30, timeout)) : 3
        return await withCheckedContinuation { continuation in
            let timeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                catch { return }
                guard let waiter = self?.hardwareWaiters.removeValue(forKey: id) else { return }
                waiter.0.resume(returning: false)
            }
            hardwareWaiters[id] = (continuation, timeoutTask)
            refreshDevices()
        }
    }
    private func receiveHardwareSnapshot(_ snapshot: AudioHardwareSnapshot) {
        hardwareReadPending = false
        if snapshot.inputs != inputDevices { inputDevices = snapshot.inputs }
        if snapshot.outputs != outputDevices { outputDevices = snapshot.outputs }
        if snapshot.processes != processes { processes = snapshot.processes }
        defaultInputDeviceID = snapshot.defaultInput; defaultOutputDeviceID = snapshot.defaultOutput
        let oldDefault = lastDefaultOutput
        lastDefaultOutput = snapshot.defaultOutput
        if oldDefault != 0, oldDefault != snapshot.defaultOutput, outputDeviceID == 0 { setOutputDevice(0) }
        let waiters = hardwareWaiters.values
        hardwareWaiters.removeAll()
        for waiter in waiters { waiter.1.cancel(); waiter.0.resume(returning: true) }
    }
    private func ensureOutput() throws {
        guard playbackCoordinator.acquire(token: playbackToken, interrupt: { [weak self] in self?.pause() }) else {
            throw NSError(domain: "Guitarget.Playback", code: 1, userInfo: [NSLocalizedDescriptionKey: "播放已由其他音频接管。"])
        }
        do {
            if !outputEngine.isRunning { outputEngine.prepare(); try outputEngine.start() }
        } catch {
            playbackCoordinator.release(token: playbackToken)
            throw error
        }
    }
    public func setOutputDevice(_ id: UInt32) {
        let wasPlaying = isPlaying, wasPaused = isPaused
        outputEngine.stop()
        playbackCoordinator.release(token: playbackToken)
        currentTick = playback.renderer?.currentTick ?? currentTick
        isPlaying = false
        isPaused = (wasPlaying || wasPaused) && playback.renderer != nil
        playback.renderer?.hostAnchor.store(-Double.infinity, ordering: .releasing)
        transportStartHostTime = nil
        var selected = id == 0 ? defaultOutputDeviceID : id
        guard let unit = outputEngine.outputNode.audioUnit else { status = "输出设备不可用" + (isPaused ? "；播放已暂停。" : ""); return }
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioObjectID>.size))
        if result != noErr { status = "切换输出设备失败（CoreAudio \(result)）；请重新选择可用输出。" + (isPaused ? " 播放已暂停。" : ""); return }
        outputDeviceID = id
        if wasPlaying && !wasPaused {
            do { try ensureOutput(); isPlaying = true; isPaused = false }
            catch { status = error.localizedDescription + " 播放已暂停。" }
        }
    }
    public func play(score: GuitarScore, owner: String, fromTick: Int = 0) {
        accompanimentOptions = nil
        beginScorePlayback(score: score, owner: owner, fromTick: fromTick)
    }
    public func playAccompaniment(score: GuitarScore, owner: String, loop: Bool = true, metronome: Bool = false, countIn: Bool = true, fromTick: Int = 0) {
        accompanimentOptions = AccompanimentPlaybackOptions(loop: loop, metronome: metronome, countIn: countIn)
        beginScorePlayback(score: score, owner: owner, fromTick: fromTick)
    }
    private func makeScoreRenderer(score: GuitarScore, fromTick: Int, includeCountIn: Bool) -> ScoreRenderer {
        if let options = accompanimentOptions {
            return options.makeRenderer(score: score, sampleRate: sampleRate, fromTick: fromTick, includeCountIn: includeCountIn)
        }
        return ScoreRenderer(score: score, sampleRate: sampleRate, speed: speed, fromTick: fromTick,
                             loopRange: loopRange, mutedVoices: mutedVoices, metronome: metronomeEnabled,
                             countIn: includeCountIn && countInEnabled)
    }
    private func beginScorePlayback(score: GuitarScore, owner: String, fromTick: Int) {
        outputEngine.stop()
        playingScore = score; ownerID = owner; transportStartHostTime = nil
        let renderer = makeScoreRenderer(score: score, fromTick: fromTick, includeCountIn: true)
        playback.renderer = renderer; currentTick = renderer.currentTick; isCountingIn = renderer.isCountingIn.load(ordering: .acquiring)
        do { try ensureOutput(); isPlaying = true; isPaused = false; status = "正在演奏：\(score.title)" }
        catch { status = "声音播放失败：\(error.localizedDescription)"; isPlaying = false; isPaused = false; isCountingIn = false }
    }
    public func preview(notes: [GuitarNote], tuning: [Int] = [64,59,55,50,45,40], owner: String, strum: Bool = false) {
        let events: [ScoreEvent]
        if strum {
            events = notes.sorted { $0.string > $1.string }.enumerated().map { index, note in
                ScoreEvent(startTick: index * 32, rhythm: Rhythm(.half), notes: [note])
            }
        } else { events = [ScoreEvent(startTick: 0, rhythm: Rhythm(.half), notes: notes)] }
        let score = GuitarScore(title: "吉他试听", tuning: tuning, bpm: 60, measures: [ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: events), VoiceTrack(voice: .bass)])])
        playPreview(score: score, owner: owner)
    }
    public func previewSequence(notes: [GuitarNote], tuning: [Int] = [64,59,55,50,45,40], owner: String, secondsPerNote: Double = 0.4) {
        guard !notes.isEmpty else { return }
        var measures: [ScoreMeasure] = []
        for start in stride(from: 0, to: notes.count, by: 4) {
            let events = notes[start..<min(start + 4, notes.count)].enumerated().map { index, note in ScoreEvent(startTick: index * 960, notes: [note]) }
            measures.append(ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: events), VoiceTrack(voice: .bass)]))
        }
        playPreview(score: GuitarScore(title: "逐音试听", tuning: tuning, bpm: 60 / max(0.1, secondsPerNote), measures: measures), owner: owner)
    }
    /// A local tuner reference uses the shared output engine and leaves every document's tuning intact.
    public func previewTunerReference(midi: Int, a4: Double, owner: String) {
        guard (0...127).contains(midi) else { return }
        var tuning = MusicTheory.standardTuning
        tuning[0] = midi
        let event = ScoreEvent(startTick: 0, rhythm: Rhythm(.half), notes: [GuitarNote(string: 1, fret: 0)])
        let score = GuitarScore(title: "调音参考 \(MusicTheory.noteName(midi: midi))", tuning: tuning,
                               timeSignature: TimeSignature(2, 4), bpm: 60,
                               measures: [ScoreMeasure(voices: [VoiceTrack(voice: .melody, events: [event]), VoiceTrack(voice: .bass)])])
        playPreview(score: score, owner: owner, referenceA4: TunerConfiguration.validReference(a4))
    }
    private func playPreview(score: GuitarScore, owner: String, referenceA4: Double = 440) {
        accompanimentOptions = nil
        outputEngine.stop(); playingScore = nil; ownerID = owner; transportStartHostTime = nil
        playback.renderer = ScoreRenderer(score: score, sampleRate: sampleRate, referenceA4: referenceA4)
        currentTick = 0; isCountingIn = false
        do { try ensureOutput(); isPlaying = true; isPaused = false; status = "示范试听中 · 暂停练习判定" }
        catch { status = error.localizedDescription; isPlaying = false }
    }
    public func pause() {
        guard isPlaying else { return }
        outputEngine.pause(); currentTick = playback.renderer?.currentTick ?? currentTick
        isPaused = true; isPlaying = false; status = "已暂停"
        playbackCoordinator.release(token: playbackToken)
    }
    public func resume() {
        guard isPaused else { return }
        playback.renderer?.hostAnchor.store(-Double.infinity, ordering: .releasing)
        transportStartHostTime = nil
        do { try ensureOutput(); isPlaying = true; isPaused = false; status = "继续演奏" }
        catch { status = error.localizedDescription }
    }
    public func stop() {
        accompanimentOptions = nil
        outputEngine.stop(); playback.renderer = nil; playingScore = nil
        playbackCoordinator.release(token: playbackToken)
        isPlaying = false; isPaused = false; isCountingIn = false; currentTick = 0; ownerID = nil; transportStartHostTime = nil
        status = isCapturing ? "正在采集 · 等待单音" : "已停止 · 采集已关闭"
    }
    public func seek(to tick: Int) {
        isCountingIn = false
        guard let score = playingScore, let owner = ownerID else { currentTick = max(0, tick); return }
        let wasPlaying = isPlaying
        outputEngine.stop(); transportStartHostTime = nil
        playback.renderer = makeScoreRenderer(score: score, fromTick: tick, includeCountIn: false)
        currentTick = max(0, min(score.totalTicks, tick)); ownerID = owner
        if wasPlaying {
            do { try ensureOutput() } catch { status = error.localizedDescription; isPlaying = false }
        } else { isPaused = true }
    }
    private func rebuildPlayback() {
        if accompanimentOptions == nil, playingScore != nil { seek(to: playback.renderer?.currentTick ?? currentTick) }
    }
    public func startCapture() {
        stopCapture()
        guard source != .off else { return }
        // A cancelled HAL start/stop can still be in flight. Its callbacks must retain
        // only its own ring; never let them become a second producer for a new capture.
        analyzer = CaptureAnalyzer()
        configureAnalyzerDelivery()
        let generation = captureGeneration
        if source == .input {
            isStartingCapture = true
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: beginInputCapture(generation: generation)
            case .notDetermined:
                status = "请求麦克风权限…"
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    Task { @MainActor in
                        guard let self, self.captureGeneration == generation, self.source == .input else { return }
                        if granted { self.beginInputCapture(generation: generation) }
                        else { self.isStartingCapture = false; self.status = "麦克风权限被拒绝；可继续编辑与试听。请在系统设置 → 隐私与安全性 → 麦克风中授权。" }
                    }
                }
            default: isStartingCapture = false; status = "麦克风权限被拒绝；可继续编辑与试听。请在系统设置 → 隐私与安全性 → 麦克风中授权。"
            }
        } else {
            let process = selectedProcessID.flatMap { id in processes.first { $0.id == id } }
            if selectedProcessID != nil && process == nil { status = "所选 App 已退出，请刷新后重新选择。"; return }
            beginSystemCapture(process: process, generation: generation)
        }
    }
    private func beginSystemCapture(process: AudioProcess?, generation: Int) {
        isStartingCapture = true; status = "正在启动系统声音采集…"
        systemCaptureDiagnostics = [:]; systemInspectionPending = false
        let session = SystemTapSession(ring: analyzer.ring, queue: hardwareQueue, factory: systemTapFactory)
        processTap = session
        analyzer.start(generation: generation)
        systemStartTimeout = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(self.systemStartTimeoutSeconds * 1_000_000_000)) } catch { return }
            guard self.captureGeneration == generation, self.isStartingCapture else { return }
            self.stopCapture()
            self.status = "系统声音启动超时；请求已取消。系统返回后将释放采集资源，可继续编辑。"
        }
        session.start(process: process) { [weak self] result in
            Task { @MainActor in
                guard let self, self.captureGeneration == generation, self.source == .system, self.processTap === session else {
                    session.cancel(); return
                }
                self.systemStartTimeout?.cancel(); self.systemStartTimeout = nil
                switch result {
                case .success(let diagnostics):
                    self.systemCaptureDiagnostics = diagnostics
                    self.markCaptureStarted()
                    self.status = "正在采集系统声音：\(process?.name ?? "整机混音") · 已排除 Guitarget"
                case .failure(let error):
                    self.stopCapture(); self.status = error.localizedDescription
                }
            }
        }
    }
    private func beginInputCapture(generation: Int) {
        guard captureGeneration == generation, source == .input else { return }
        do {
            let engine = AVAudioEngine(), node = engine.inputNode
            let selectedID = inputDeviceID == 0 ? defaultInputDeviceID : inputDeviceID
            var device = selectedID
            guard let unit = node.audioUnit else { throw AudioFailure(operation: "打开声音输入", code: kAudioHardwareBadDeviceError) }
            inputEngine = engine; activeInputDevice = selectedID
            status = "正在协商声音输入格式…"
            // CurrentDevice can return before AVAudioEngine has adopted the device's format.
            // Observe first, and only install a tap once the hardware format is current.
            inputConfigurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                // Engine notifications originate on an internal queue; never tear down there.
                Task { @MainActor in self?.inputConfigurationChanged(generation: generation) }
            }
            inputStartTimeout = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.captureGeneration == generation, self.isStartingCapture else { return }
                    NSLog("Guitarget input format negotiation timeout: %@", self.captureDiagnostics.description)
                    self.stopCapture(); self.status = "声音输入格式协商超时，采集未启动。请检查设备后重新开始。"
                }
            }
            var currentDevice: AudioObjectID = 0
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try audioCheck(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &currentDevice, &size), "读取当前输入设备")
            // A redundant assignment can itself enqueue another configuration change.
            if currentDevice != selectedID {
                try audioCheck(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, size), "选择输入设备")
            }
            finishInputCaptureIfReady(generation: generation)
        } catch { stopCapture(); status = error.localizedDescription }
    }
    private func finishInputCaptureIfReady(generation: Int) {
        guard captureGeneration == generation, source == .input, isStartingCapture,
              let engine = inputEngine, let unit = engine.inputNode.audioUnit else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            stopCapture(); status = "麦克风权限发生变化；采集未启动。"; return
        }
        let node = engine.inputNode
        var currentDevice: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let deviceResult = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &currentDevice, &size)
        let format = node.inputFormat(forBus: 0)
        let rate = audioScalar(activeInputDevice, selector: kAudioDevicePropertyNominalSampleRate, initial: 0.0)
        // Same-format devices may never send a configuration notification, so readiness
        // is determined by the hardware format, not a notification count or fixed sleep.
        // installTap applies this format to the unconnected output bus. Its previous
        // client format need not change until we configure it here.
        guard deviceResult == noErr, currentDevice == activeInputDevice, rate > 0,
              format.channelCount > 0, abs(format.sampleRate - rate) < 1 else { return }
        clearInputStartWait(removeObserver: false)
        isStartingCapture = false
        do {
            guard format.commonFormat == .pcmFormatFloat32 else { throw AudioFailure(operation: "输入格式不支持 Float32", code: kAudioFormatUnsupportedDataFormatError) }
            let channel = min(max(0, inputChannel), Int(format.channelCount) - 1)
            inputChannel = channel
            let ring = analyzer.ring
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
                guard channel < Int(buffer.format.channelCount), let data = buffer.floatChannelData else { return }
                let timestamp = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : ProcessInfo.processInfo.systemUptime
                if buffer.format.isInterleaved {
                    ring.write(data[0].advanced(by: channel), count: Int(buffer.frameLength), stride: Int(buffer.format.channelCount), rate: buffer.format.sampleRate, time: timestamp)
                } else { ring.write(data[channel], count: Int(buffer.frameLength), stride: 1, rate: buffer.format.sampleRate, time: timestamp) }
            }
            inputTapInstalled = true
            inputCaptureFormat = format
            analyzer.start(generation: generation)
            engine.prepare(); try engine.start()
            markCaptureStarted()
            let name = inputDevices.first { $0.id == activeInputDevice }?.name ?? "系统默认输入"
            status = "正在采集：\(name) · 通道 \(channel + 1)"
        } catch { stopCapture(); status = error.localizedDescription }
    }
    private func inputConfigurationChanged(generation: Int) {
        guard captureGeneration == generation, source == .input, let engine = inputEngine else { return }
        if isStartingCapture { finishInputCaptureIfReady(generation: generation); return }
        let format = engine.inputNode.inputFormat(forBus: 0)
        let expected = inputCaptureFormat
        var device: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let result = engine.inputNode.audioUnit.map { AudioUnitGetProperty($0, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) }
        let formatMatches = result == noErr && device == activeInputDevice && expected?.sampleRate == format.sampleRate && expected?.channelCount == format.channelCount
        handleRunningInputConfigurationChange(generation: generation, engineIsRunning: engine.isRunning, formatMatches: formatMatches)
    }
    func handleRunningInputConfigurationChange(generation: Int, engineIsRunning: Bool, formatMatches: Bool) {
        guard captureGeneration == generation, source == .input, isCapturing else { return }
        // A startup notification can arrive on the main actor after start() succeeded.
        // Ignore that stale notification only while the engine and capture format agree.
        guard !engineIsRunning || !formatMatches else { return }
        stopCapture(); status = "输入设备配置或采样率发生变化；采集已停止，请重新开始。"
    }
    private func clearInputStartWait(removeObserver: Bool = true) {
        if removeObserver {
            if let observer = inputConfigurationObserver { NotificationCenter.default.removeObserver(observer) }
            inputConfigurationObserver = nil
        }
        inputStartTimeout?.invalidate(); inputStartTimeout = nil
    }
    func markCaptureStarted() {
        isStartingCapture = false; isCapturing = true; captureStartedAt = ProcessInfo.processInfo.systemUptime; lastPitchUIUpdate = 0
        lastCaptureCount = analyzer.ring.writeIndex.load(ordering: .relaxed); captureIdleChecks = 0
    }
    public func stopCapture() {
        captureGeneration += 1
        systemStartTimeout?.cancel(); systemStartTimeout = nil
        clearInputStartWait()
        if let inputEngine { inputEngine.stop(); if inputTapInstalled { inputEngine.inputNode.removeTap(onBus: 0) } }
        inputTapInstalled = false; inputCaptureFormat = nil
        inputEngine = nil; activeInputDevice = 0; processTap?.cancel(); processTap = nil; analyzer.stop()
        systemInspectionPending = false; systemCaptureDiagnostics = [:]
        isStartingCapture = false; isCapturing = false; pitchFrame = nil; inputLevel = 0; lastPitchUIUpdate = 0
        if !isPlaying { status = "采集已关闭 · 可继续编辑与试听" }
    }
    private func update() {
        if isPlaying, let renderer = playback.renderer {
            let countingIn = renderer.isCountingIn.load(ordering: .acquiring)
            if isCountingIn != countingIn { isCountingIn = countingIn }
            let anchor = renderer.hostAnchor.load(ordering: .acquiring)
            if anchor.isFinite && transportStartHostTime != anchor { transportStartHostTime = anchor }
            currentTick = min(renderer.score.totalTicks, renderer.currentTick)
            if renderer.finished.load(ordering: .acquiring) {
                outputEngine.stop(); isPlaying = false; isPaused = false; isCountingIn = false; status = "演奏结束"
                playbackCoordinator.release(token: playbackToken)
            }
        }
        monitorCounter += 1
        guard monitorCounter >= 30 else { return }
        monitorCounter = 0; refreshDevices()
        if outputDeviceID != 0 && !outputDevices.contains(where: { $0.id == outputDeviceID }) {
            stop(); setOutputDevice(0); status = "输出设备已断开，已停止演奏并恢复系统默认输出。"
        }
        guard isCapturing else { return }
        if source == .input && activeInputDevice != 0 && !inputDevices.contains(where: { $0.id == activeInputDevice }) {
            stopCapture(); status = "输入设备已断开；采集已停止。"; return
        }
        if source == .input && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            stopCapture(); status = "麦克风权限发生变化；采集已停止。"; return
        }
        if source == .system, let processTap, !systemInspectionPending {
            systemInspectionPending = true
            let generation = captureGeneration
            processTap.inspect { [weak self] diagnostics, clockChanged in
                Task { @MainActor in
                    guard let self, self.captureGeneration == generation, self.processTap === processTap else { return }
                    self.systemInspectionPending = false; self.systemCaptureDiagnostics = diagnostics
                    if clockChanged { self.stopCapture(); self.status = "系统输出设备或采样率发生变化；系统声音采集已停止，请重新开始。" }
                }
            }
        }
        if source == .system, let selectedProcessID, !processes.contains(where: { $0.id == selectedProcessID }) {
            stopCapture(); status = "来源 App 已退出；系统声音采集已停止。"; return
        }
        let captured = analyzer.ring.writeIndex.load(ordering: .relaxed)
        captureIdleChecks = captured == lastCaptureCount ? captureIdleChecks + 1 : 0
        lastCaptureCount = captured
        if captureIdleChecks >= 4 && ProcessInfo.processInfo.systemUptime - captureStartedAt > 4 {
            NSLog("Guitarget capture timeout: %@", captureDiagnostics.description)
            stopCapture(); status = "未收到音频帧，采集已停止。请检查设备，以及系统设置 → 隐私与安全性中的麦克风或屏幕与系统音频录制授权。"
        }
    }
}
