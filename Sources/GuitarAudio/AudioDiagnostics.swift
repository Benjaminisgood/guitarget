import Foundation
import AVFoundation
import GuitarCore

/// Explicit development self-check. Does not initialize AudioService or request capture access.
public enum AudioDiagnostics {
    public static func run(outputDirectory: URL) throws -> [String: Any] {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let rate = 48000.0
        let demoURL = outputDirectory.appendingPathComponent("steel-string-demo.wav")
        let referenceURL = outputDirectory.appendingPathComponent("reference-a4.wav")
        var measurements: [[String: Any]] = []
        for (string, midi) in [64,59,55,50,45,40].enumerated() {
            let expected = 440 * pow(2, Double(midi - 69) / 12)
            let synth = GuitarSynthesizer(sampleRate: rate)
            synth.pluck(string: string + 1, frequency: expected)
            _ = synth.render(frames: 2048)
            let samples = synth.render(frames: 4096)
            let start = ProcessInfo.processInfo.systemUptime
            var decimated = [Float]()
            decimated.reserveCapacity(samples.count / 2)
            for index in stride(from: 0, to: samples.count - 1, by: 2) { decimated.append((samples[index] + samples[index + 1]) * Float(0.5)) }
            let detected = YINDetector().detect(decimated, sampleRate: rate / 2, timestamp: 0.085333)
            let elapsedMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            var measurement: [String: Any] = ["string": string + 1, "midi": midi, "expectedHz": expected, "processingMilliseconds": elapsedMS, "analysisWindowMilliseconds": 4096 / rate * 1000]
            if let detected {
                let error = 1200 * log2(detected.frequency / expected)
                measurement["detectedHz"] = detected.frequency
                measurement["centsError"] = error
                measurement["confidence"] = detected.confidence
                measurement["passed"] = detected.midi == midi && abs(error) < 15
            } else { measurement["passed"] = false; measurement["reason"] = "YIN 未得到可信单音" }
            measurements.append(measurement)
        }
        let synth = GuitarSynthesizer(sampleRate: rate)
        var demo: [Float] = []
        // Six open strings, low to high, then a fingerpicked C chord, followed by each technique.
        for (string, midi) in zip([6,5,4,3,2,1], [40,45,50,55,59,64]) {
            synth.pluck(string: string, frequency: 440 * pow(2, Double(midi - 69) / 12))
            demo.append(contentsOf: synth.render(frames: Int(rate * 0.7)))
        }
        synth.reset()
        for (string, midi) in [(5,48),(4,52),(3,55),(2,60),(1,64)] {
            synth.pluck(string: string, frequency: 440 * pow(2, Double(midi - 69) / 12))
            demo.append(contentsOf: synth.render(frames: Int(rate * 0.018)))
        }
        demo.append(contentsOf: synth.render(frames: Int(rate * 2.0)))
        for technique in GuitarTechnique.allCases {
            synth.reset()
            if technique == .hammerOn || technique == .pullOff {
                synth.pluck(string: 3, frequency: technique == .hammerOn ? 196 : 246.94)
                demo.append(contentsOf: synth.render(frames: Int(rate * 0.18)))
            }
            synth.pluck(string: 3, frequency: 220, technique: technique, targetFrequency: technique == .pullOff ? 196 : 246.94)
            demo.append(contentsOf: synth.render(frames: Int(rate * 0.65)))
        }
        demo.append(contentsOf: synth.render(frames: Int(rate * 0.4)))
        try write(samples: demo, sampleRate: rate, to: demoURL)
        let referenceFrames = Int(rate * 10)
        let reference = (0..<referenceFrames).map { i -> Float in
            let fade = min(1, Double(i) / (rate * 0.015), Double(referenceFrames - 1 - i) / (rate * 0.015))
            return Float(0.22 * max(0, fade) * sin(2 * .pi * 440 * Double(i) / rate))
        }
        try write(samples: reference, sampleRate: rate, to: referenceURL)
        // Stress six active strings, including continuous delay modulation, in 256-frame blocks.
        let renderProbe = GuitarSynthesizer(sampleRate: rate)
        for (index, midi) in [64,59,55,50,45,40].enumerated() {
            let techniques: [GuitarTechnique] = [.vibrato,.slide,.bendHalf,.bendFull,.none,.none]
            let frequency = 440 * pow(2, Double(midi - 69) / 12)
            renderProbe.pluck(string: index + 1, frequency: frequency, technique: techniques[index], targetFrequency: frequency * pow(2, 2.0 / 12))
        }
        var blockTimes = [Double]()
        var checksum = 0.0
        for block in 0..<256 {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<256 { checksum += Double(renderProbe.sample()) }
            let time = (ProcessInfo.processInfo.systemUptime - start) * 1000
            if block >= 4 { blockTimes.append(time) }
        }
        let renderBudget = 256 / rate * 1000
        let renderMean = blockTimes.reduce(0, +) / Double(blockTimes.count)
        let renderMax = blockTimes.max() ?? 0
        // Strummed open chords through the polyphonic recogniser, decided by majority vote
        // over the frames centred 0.55–1.05 s after the strum.
        var chordMeasurements: [[String: Any]] = []
        var chordHops = 0
        var chordSeconds = 0.0
        let openChords: [(ChordDefinition, [Int?])] = [
            (ChordDefinition(root: .c, kind: .major), [0, 1, 0, 2, 3, nil]), (ChordDefinition(root: .g, kind: .major), [3, 0, 0, 0, 2, 3]),
            (ChordDefinition(root: .d, kind: .major), [2, 3, 2, 0, nil, nil]), (ChordDefinition(root: .a, kind: .major), [0, 2, 2, 2, 0, nil]),
            (ChordDefinition(root: .e, kind: .major), [0, 0, 1, 2, 2, 0]), (ChordDefinition(root: .a, kind: .minor), [0, 1, 2, 2, 0, nil]),
            (ChordDefinition(root: .e, kind: .minor), [0, 0, 0, 2, 2, 0]), (ChordDefinition(root: .d, kind: .minor), [1, 3, 2, 0, nil, nil])
        ]
        for (chord, frets) in openChords {
            let strum = GuitarSynthesizer(sampleRate: rate)
            var samples: [Float] = []
            for string in (1...6).reversed() {
                guard let fret = frets[string - 1] else { continue }
                strum.pluck(string: string, frequency: 440 * pow(2, Double(MusicTheory.standardTuning[string - 1] + fret - 69) / 12), velocity: 0.8)
                samples.append(contentsOf: strum.render(frames: Int(rate * 0.012)))
            }
            samples.append(contentsOf: strum.render(frames: Int(rate * 1.2) - samples.count))
            var tracker = ChordTracker(sampleRate: rate)
            var frames: [ChordFrame] = []
            for start in stride(from: 0, to: samples.count, by: 1024) {
                let began = ProcessInfo.processInfo.systemUptime
                let produced = tracker.consume(Array(samples[start..<min(start + 1024, samples.count)]), startTime: Double(start) / rate, onsetTimestamp: nil)
                chordSeconds += ProcessInfo.processInfo.systemUptime - began
                chordHops += produced.count
                frames.append(contentsOf: produced.compactMap { $0 })
            }
            let decided = frames.filter { $0.timestamp > 0.55 && $0.timestamp < 1.05 }
            let votes = Dictionary(grouping: decided, by: { $0.chord.withoutBass }).mapValues(\.count)
            let winner = votes.max { $0.value < $1.value }?.key
            chordMeasurements.append([
                "chord": chord.name, "frets": frets.reversed().map { $0.map(String.init) ?? "x" }.joined(),
                "recognised": winner?.label ?? "—", "passed": winner == .chord(chord, bass: nil),
                "meanFit": decided.isEmpty ? 0 : decided.reduce(0) { $0 + $1.fit } / Double(decided.count),
                "firstMatchSeconds": frames.first { $0.chord.withoutBass == .chord(chord, bass: nil) }?.timestamp ?? -1
            ])
        }
        let chordHopMilliseconds = chordHops > 0 ? chordSeconds / Double(chordHops) * 1000 : 0
        let chordBudget = 2048 / rate * 1000
        let report: [String: Any] = [
            "passed": measurements.allSatisfy { $0["passed"] as? Bool == true } && chordMeasurements.allSatisfy { $0["passed"] as? Bool == true },
            "sampleRate": rate,
            "algorithm": "Swift fractional-delay Karplus-Strong + YIN + NNLS chroma / HMM chord recognition",
            "steelStringDemo": demoURL.path,
            "referenceA4": referenceURL.path,
            "measurements": measurements,
            "chordMeasurements": chordMeasurements,
            "chordBenchmark": ["windowFrames": 16384, "hopFrames": 2048, "hopBudgetMilliseconds": chordBudget, "meanHopMilliseconds": chordHopMilliseconds, "averageRealtimeLoadPercent": chordHopMilliseconds / chordBudget * 100],
            "renderBenchmark": ["activeStrings": 6, "blockFrames": 256, "budgetMilliseconds": renderBudget, "meanBlockMilliseconds": renderMean, "maximumBlockMilliseconds": renderMax, "averageRealtimeLoadPercent": renderMean / renderBudget * 100, "checksum": checksum],
            "processingBudgetPassed": measurements.allSatisfy { ($0["processingMilliseconds"] as? Double ?? .infinity) < 25 } && renderMax < renderBudget && chordHopMilliseconds < chordBudget / 4,
            "hardwareCaptureTested": false,
            "realGuitarTested": false,
            "note": "离线合成/算法自检；处理耗时不等于端到端输入延迟，也不代表真琴准确率。和弦识别结果来自合成扫弦，真琴与麦克风准确率未测量。"
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputDirectory.appendingPathComponent("audio-diagnostics.json"), options: .atomic)
        return report
    }
    private static func write(samples: [Float], sampleRate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in buffer.floatChannelData![0].update(from: source.baseAddress!, count: source.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
