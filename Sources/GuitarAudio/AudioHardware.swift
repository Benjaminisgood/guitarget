import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import AppKit
import Synchronization

public struct AudioDevice: Identifiable, Equatable, Sendable {
    public var id: UInt32
    public var name: String
    public var channels: Int
    public var nominalSampleRate: Double
    public var transportType: UInt32
    public init(id: UInt32, name: String, channels: Int, nominalSampleRate: Double = 0, transportType: UInt32 = 0) {
        self.id = id; self.name = name; self.channels = channels
        self.nominalSampleRate = nominalSampleRate; self.transportType = transportType
    }
}
public struct AudioProcess: Identifiable, Equatable, Sendable {
    public var id: Int32
    public var objectID: UInt32
    public var name: String
    public var bundleID: String
}
public enum CaptureSource: String, CaseIterable, Identifiable, Sendable {
    case off, input, system
    public var id: String { rawValue }
    public var title: String { switch self { case .off: return "关闭采集"; case .input: return "声音输入"; case .system: return "系统声音" } }
}

struct AudioFailure: LocalizedError {
    var operation: String
    var code: OSStatus
    var errorDescription: String? { "\(operation)失败（CoreAudio \(code)）。请检查设备与系统设置中的录音权限。" }
}

func audioCheck(_ code: OSStatus, _ operation: String) throws {
    if code != noErr { throw AudioFailure(operation: operation, code: code) }
}

func audioIDs(_ selector: AudioObjectPropertySelector, object: AudioObjectID = AudioObjectID(kAudioObjectSystemObject), scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values) == noErr else { return [] }
    return values
}
func audioName(_ object: AudioObjectID, selector: AudioObjectPropertySelector = kAudioObjectPropertyName) -> String {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let storage = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
    storage.initialize(to: nil)
    defer { storage.deinitialize(count: 1); storage.deallocate() }
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage) == noErr,
          let value = storage.pointee else { return "未知设备" }
    return value.takeRetainedValue() as String
}
func audioScalar<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector, initial: T) -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let storage = UnsafeMutablePointer<T>.allocate(capacity: 1)
    storage.initialize(to: initial)
    defer { storage.deinitialize(count: 1); storage.deallocate() }
    var size = UInt32(MemoryLayout<T>.size)
    _ = AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage)
    return storage.pointee
}
func audioDevices(input: Bool) -> [AudioDevice] {
    audioIDs(kAudioHardwarePropertyDevices).compactMap { id in
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0 else { return nil }
        let name = audioName(id)
        guard !name.hasPrefix("Guitarget Capture") else { return nil }
        return AudioDevice(id: id, name: name, channels: channels,
                           nominalSampleRate: audioScalar(id, selector: kAudioDevicePropertyNominalSampleRate, initial: 0.0),
                           transportType: audioScalar(id, selector: kAudioDevicePropertyTransportType, initial: UInt32(0)))
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}
func audioProcesses() -> [AudioProcess] {
    audioIDs(kAudioHardwarePropertyProcessObjectList).compactMap { id in
        let pid = audioScalar(id, selector: kAudioProcessPropertyPID, initial: Int32(0))
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let bundle = audioName(id, selector: kAudioProcessPropertyBundleID)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? bundle.split(separator: ".").last.map(String.init) ?? "进程 \(pid)"
        return AudioProcess(id: pid, objectID: id, name: name, bundleID: bundle)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}
func audioProcessID(pid: Int32) -> AudioObjectID {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var pid = pid, result: AudioObjectID = 0, size = UInt32(MemoryLayout<AudioObjectID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<Int32>.size), &pid, &size, &result)
    return result
}

private final class TapCounters: @unchecked Sendable {
    let callbacks = Atomic<Int>(0)
    let inputBuffers = Atomic<Int>(0)
    let inputBytes = Atomic<Int>(0)
}

final class ProcessTapCapture: SystemTapBackend {
    private let counters = TapCounters()
    private var clockName = ""
    private var clockDeviceID: AudioObjectID = 0
    private var clockSampleRate = 0.0
    private var tapReportedRate = 0.0
    private var streamReportedRate = 0.0
    private var capturedRate = 0.0
    private var configuredInputStreams = 0
    private var configuredOutputStreams = 0
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private let ring: CaptureRing
    private let cancellation: CaptureCancellation
    init(ring: CaptureRing, cancellation: CaptureCancellation = CaptureCancellation()) { self.ring = ring; self.cancellation = cancellation }
    deinit { stop() }
    func start(process: AudioProcess?) throws {
        stop()
        try cancellation.check()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownID = audioProcessID(pid: ownPID)
        let ownBundleID = Bundle.main.bundleIdentifier
        let canExcludeByBundle: Bool
        if #available(macOS 26.0, *) { canExcludeByBundle = ownBundleID?.isEmpty == false }
        else { canExcludeByBundle = false }
        guard (ownID != 0 || canExcludeByBundle), process?.id != ownPID else { throw AudioFailure(operation: "无法确认自身声音排除", code: kAudioHardwareBadObjectError) }
        let description: CATapDescription
        if let process {
            description = CATapDescription(monoMixdownOfProcesses: [process.objectID])
            if #available(macOS 26.0, *), !process.bundleID.isEmpty, process.bundleID != "未知设备" { description.bundleIDs = [process.bundleID] }
        } else {
            description = CATapDescription(monoGlobalTapButExcludeProcesses: ownID == 0 ? [] : [ownID])
            if #available(macOS 26.0, *), let bundle = ownBundleID { description.bundleIDs = [bundle] }
        }
        description.name = "Guitarget 单音分析"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        do {
            // macOS presents its system-audio recording consent on first creation/use.
            try audioCheck(AudioHardwareCreateProcessTap(description, &tapID), "创建系统音频采集")
            try cancellation.check()
            var format = AudioStreamBasicDescription()
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try audioCheck(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "读取系统音频格式")
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
                throw AudioFailure(operation: "系统音频格式不支持 Float32", code: kAudioFormatUnsupportedDataFormatError)
            }
            let clockID = audioScalar(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
            let clockUID = audioName(clockID, selector: kAudioDevicePropertyDeviceUID)
            guard clockID != 0, clockUID != "未知设备", !clockUID.isEmpty else {
                throw AudioFailure(operation: "系统采集缺少输出设备时钟", code: kAudioHardwareBadDeviceError)
            }
            clockName = audioName(clockID); clockDeviceID = clockID
            clockSampleRate = audioScalar(clockID, selector: kAudioDevicePropertyNominalSampleRate, initial: 0.0)
            tapReportedRate = format.mSampleRate
            let actualTapUID = audioName(tapID, selector: kAudioTapPropertyUID)
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Guitarget Capture \(UUID().uuidString.prefix(8))",
                kAudioAggregateDeviceUIDKey: "com.guitarget.capture.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: clockUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID, kAudioSubDeviceInputChannelsKey: 0]],
                // With a hardware clock, start immediately and provide silence when sources are quiet.
                // tapautostart=true can wait indefinitely for a process start transition.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: actualTapUID, kAudioSubTapDriftCompensationKey: true]]
            ]
            try audioCheck(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "创建私有系统采集设备")
            try cancellation.check()
            // The aggregate may resample the tap to its hardware clock (e.g. a 44.1 kHz Bluetooth output).
            // Interpret the actual IO stream format, not the tap's pre-aggregate format.
            guard let tapStream = audioIDs(kAudioDevicePropertyStreams, object: aggregateID, scope: kAudioDevicePropertyScopeInput).last else {
                throw AudioFailure(operation: "系统采集没有输入流", code: kAudioHardwareBadStreamError)
            }
            var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var streamFormat = AudioStreamBasicDescription()
            var streamSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try audioCheck(AudioObjectGetPropertyData(tapStream, &streamAddress, 0, nil, &streamSize, &streamFormat), "读取系统采集实际格式")
            guard streamFormat.mFormatID == kAudioFormatLinearPCM, streamFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0, streamFormat.mBitsPerChannel == 32, streamFormat.mSampleRate > 0 else {
                throw AudioFailure(operation: "系统采集输入流格式不支持 Float32", code: kAudioFormatUnsupportedDataFormatError)
            }
            streamReportedRate = streamFormat.mSampleRate
            // IOProc's frame count/timebase is the aggregate device's negotiated nominal rate.
            // A process tap may continue reporting its original 48 kHz virtual format on a 44.1 kHz clock.
            let aggregateRate = audioScalar(aggregateID, selector: kAudioDevicePropertyNominalSampleRate, initial: streamFormat.mSampleRate)
            capturedRate = aggregateRate > 0 ? aggregateRate : streamFormat.mSampleRate
            let ring = self.ring, rate = capturedRate, counters = self.counters, cancellation = self.cancellation
            counters.callbacks.store(0, ordering: .relaxed)
            counters.inputBuffers.store(0, ordering: .relaxed)
            counters.inputBytes.store(0, ordering: .relaxed)
            try audioCheck(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { _, input, time, output, _ in
                let outputs = UnsafeMutableAudioBufferListPointer(output)
                for buffer in outputs {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                guard !cancellation.isCancelled else { return }
                _ = counters.callbacks.wrappingAdd(1, ordering: .relaxed)
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                counters.inputBuffers.store(buffers.count, ordering: .relaxed)
                // Aggregate input streams list the physical subdevice first and tap last.
                // Only the tap stream is enabled below, so never mistake an interface's mic for system audio.
                guard let last = buffers.last, let data = last.mData else { return }
                _ = counters.inputBytes.wrappingAdd(Int(last.mDataByteSize), ordering: .relaxed)
                let channels = max(1, Int(last.mNumberChannels))
                let count = Int(last.mDataByteSize) / MemoryLayout<Float>.size / channels
                guard count > 0 else { return }
                let timestamp = AVAudioTime.seconds(forHostTime: time.pointee.mHostTime)
                ring.write(data.assumingMemoryBound(to: Float.self), count: count, stride: channels, rate: rate, time: timestamp)
            }, "注册系统音频回调")
            try cancellation.check()
            configuredInputStreams = try setStreamUsage(scope: kAudioDevicePropertyScopeInput, useLast: true)
            configuredOutputStreams = try setStreamUsage(scope: kAudioDevicePropertyScopeOutput, useLast: false)
            NSLog("Guitarget system capture prepared: %@", diagnostics.description)
            try cancellation.check()
            try audioCheck(AudioDeviceStart(aggregateID, ioProc), "启动系统声音")
        } catch { stop(); throw error }
    }
    var diagnostics: [String: Any] {
        ["tapID": tapID, "aggregateID": aggregateID, "clock": clockName, "clockSampleRate": clockSampleRate, "tapReportedSampleRate": tapReportedRate, "streamReportedSampleRate": streamReportedRate, "capturedSampleRate": capturedRate, "inputStreams": configuredInputStreams, "outputStreams": configuredOutputStreams, "callbacks": counters.callbacks.load(ordering: .relaxed), "inputBuffers": counters.inputBuffers.load(ordering: .relaxed), "inputBytes": counters.inputBytes.load(ordering: .relaxed)]
    }
    var clockConfigurationChanged: Bool {
        let currentDefault = audioScalar(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
        let currentRate = audioScalar(clockDeviceID, selector: kAudioDevicePropertyNominalSampleRate, initial: 0.0)
        return currentDefault != clockDeviceID || abs(currentRate - clockSampleRate) > 1
    }
    private func setStreamUsage(scope: AudioObjectPropertyScope, useLast: Bool) throws -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try audioCheck(AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size), "读取系统采集流")
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        guard count > 0, let ioProc else { return count }
        let usageSize = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + max(0, count - 1) * MemoryLayout<UInt32>.size
        let storage = UnsafeMutableRawPointer.allocate(byteCount: usageSize, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: usageSize)
        defer { storage.deallocate() }
        let usage = storage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(ioProc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(count)
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let flags = storage.advanced(by: offset).assumingMemoryBound(to: UInt32.self)
        for index in 0..<count { flags[index] = useLast && index == count - 1 ? 1 : 0 }
        address.mSelector = kAudioDevicePropertyIOProcStreamUsage
        try audioCheck(AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(usageSize), storage), "配置系统采集流隔离")
        return count
    }
    func stop() {
        if aggregateID != 0 {
            if let ioProc { AudioDeviceStop(aggregateID, ioProc); AudioDeviceDestroyIOProcID(aggregateID, ioProc) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProc = nil; aggregateID = 0
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }
}
