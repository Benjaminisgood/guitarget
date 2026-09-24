import Foundation
import AVFoundation
import Combine
import GuitarAudio
import GuitarCore

/// Plays a synthesised strummed progression from a separate process and recognises it through
/// the live CoreAudio process tap, ring buffer and analysis queue. Runs only through the explicit
/// development flag; it proves the capture path, not real-guitar accuracy.
@MainActor
func runChordRecognitionSmoke(outputDirectory: URL) async -> [String: Any] {
    let audio = AudioService.shared
    let previousSource = audio.source, previousProcess = audio.selectedProcessID
    var child: Process?
    var frames: [ChordFrame] = []
    var collecting = false
    let subscription = audio.chordFrames.sink { if collecting { frames.append($0) } }
    var result: [String: Any] = ["kind": "chord-recognition-system-tap", "startedAt": ISO8601DateFormatter().string(from: Date()), "realGuitarTested": false]
    defer {
        subscription.cancel()
        if let child, child.isRunning { child.terminate() }
        audio.stopCapture()
        audio.source = previousSource; audio.selectedProcessID = previousProcess
    }
    let progression: [(chord: RecognizedChord, frets: [Int?])] = [
        (.chord(ChordDefinition(root: .c, kind: .major), bass: nil), [0, 1, 0, 2, 3, nil]),
        (.chord(ChordDefinition(root: .g, kind: .major), bass: nil), [3, 0, 0, 0, 2, 3]),
        (.chord(ChordDefinition(root: .a, kind: .minor), bass: nil), [0, 1, 2, 2, 0, nil]),
        (.chord(ChordDefinition(root: .f, kind: .major), bass: nil), [1, 1, 2, 3, 3, 1]),
        (.chord(ChordDefinition(root: .c, kind: .major), bass: .e), [0, 1, 0, 2, 3, 0])
    ]
    do {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let rate = 48000.0
        let synth = GuitarSynthesizer(sampleRate: rate)
        // Leading silence lets the tap start before the first strum; trailing silence lets the last chord settle.
        var samples = [Float](repeating: 0, count: Int(rate * 1.5))
        for entry in progression {
            synth.reset()
            var strummed = 0
            for string in (1...6).reversed() {
                guard let fret = entry.frets[string - 1] else { continue }
                synth.pluck(string: string, frequency: MusicTheory.frequency(midi: Double(MusicTheory.standardTuning[string - 1] + fret)), velocity: 0.8)
                samples.append(contentsOf: synth.render(frames: Int(rate * 0.012))); strummed += Int(rate * 0.012)
            }
            samples.append(contentsOf: synth.render(frames: Int(rate * 1.6) - strummed))
        }
        samples.append(contentsOf: [Float](repeating: 0, count: Int(rate * 0.8)))
        let wav = outputDirectory.appendingPathComponent("chord-progression.wav")
        try writeSmokeWAV(samples, sampleRate: rate, to: wav)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); player.arguments = [wav.path]
        player.standardOutput = FileHandle.nullDevice; player.standardError = FileHandle.nullDevice
        try player.run(); child = player
        audio.stop(); audio.stopCapture(); audio.source = .system
        try? await Task.sleep(for: .seconds(0.4))
        try await refreshCaptureDevices(audio)
        guard let process = audio.processes.first(where: { $0.id == player.processIdentifier }) else {
            throw NSError(domain: "GuitargetChordSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "afplay 未登记到 CoreAudio"])
        }
        audio.selectedProcessID = process.id
        try await startSystemCaptureForSmoke(audio)
        collecting = true
        let deadline = ProcessInfo.processInfo.systemUptime + 14
        while player.isRunning && ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        collecting = false
        // Collapse frames into runs of one symbol, ignoring inversion labels for the sequence itself.
        var runs: [(chord: RecognizedChord, start: Double, end: Double, count: Int, withBass: Int)] = []
        for frame in frames {
            if let last = runs.last, last.chord == frame.chord.withoutBass {
                runs[runs.count - 1].end = frame.timestamp; runs[runs.count - 1].count += 1
                if frame.chord.bass != nil { runs[runs.count - 1].withBass += 1 }
            } else { runs.append((frame.chord.withoutBass, frame.timestamp, frame.timestamp, 1, frame.chord.bass != nil ? 1 : 0)) }
        }
        let stable = runs.filter { $0.end - $0.start >= 0.4 && $0.chord.isChord }
        let expected = progression.map { $0.chord.withoutBass }
        let sequenceMatches = stable.map(\.chord) == expected
        let inversionReported = stable.count == expected.count && stable.last.map { Double($0.withBass) / Double($0.count) > 0.6 } == true
        result["frames"] = frames.count
        result["runs"] = runs.map { ["chord": $0.chord.label, "seconds": $0.end - $0.start, "frames": $0.count, "framesWithBass": $0.withBass] }
        result["stableSequence"] = stable.map(\.chord.label)
        result["expectedSequence"] = expected.map(\.label)
        result["meanFit"] = frames.isEmpty ? 0 : frames.reduce(0) { $0 + $1.fit } / Double(frames.count)
        result["captureDiagnostics"] = audio.captureDiagnostics
        result["passed"] = sequenceMatches && inversionReported && frames.count >= 100
        result["inversionReported"] = inversionReported
    } catch { result["passed"] = false; result["error"] = error.localizedDescription; result["status"] = audio.status }
    result["finishedAt"] = ISO8601DateFormatter().string(from: Date())
    do {
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDirectory.appendingPathComponent("chord-recognition-smoke.json"), options: .atomic)
    } catch { result["writeError"] = error.localizedDescription }
    return result
}

private func writeSmokeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { source in buffer.floatChannelData![0].update(from: source.baseAddress!, count: source.count) }
    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}
