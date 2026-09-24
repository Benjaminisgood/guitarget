import Foundation
import GuitarCore

/// Iterative radix-2 complex FFT with precomputed twiddles and bit-reversal table.
/// Sizes are powers of two; the forward transform uses the e^{-2πi jk/N} convention.
struct FourierTransform: Sendable {
    let size: Int
    private let cosines: [Double]
    private let sines: [Double]
    private let reversal: [Int]

    init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        cosines = (0..<size / 2).map { cos(2 * .pi * Double($0) / Double(size)) }
        sines = (0..<size / 2).map { sin(2 * .pi * Double($0) / Double(size)) }
        let bits = size.trailingZeroBitCount
        reversal = (0..<size).map { index in
            var reversed = 0, value = index
            for _ in 0..<bits { reversed = (reversed << 1) | (value & 1); value >>= 1 }
            return reversed
        }
    }

    func transform(real: inout [Double], imaginary: inout [Double]) {
        precondition(real.count == size && imaginary.count == size)
        let size = self.size
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                cosines.withUnsafeBufferPointer { cosines in
                    sines.withUnsafeBufferPointer { sines in
                        for index in 0..<size {
                            let target = reversal[index]
                            if target > index { re.swapAt(index, target); im.swapAt(index, target) }
                        }
                        var length = 2
                        while length <= size {
                            let half = length / 2, step = size / length
                            var start = 0
                            while start < size {
                                var twiddle = 0
                                for offset in 0..<half {
                                    let wr = cosines[twiddle], wi = -sines[twiddle]
                                    let a = start + offset, b = a + half
                                    let tr = re[b] * wr - im[b] * wi
                                    let ti = re[b] * wi + im[b] * wr
                                    re[b] = re[a] - tr; im[b] = im[a] - ti
                                    re[a] += tr; im[a] += ti
                                    twiddle += step
                                }
                                start += length
                            }
                            length *= 2
                        }
                    }
                }
            }
        }
    }

    /// |X[j]|² for j in 0...size/2 of a real signal.
    func powerSpectrum(_ samples: [Double]) -> [Double] {
        var real = samples, imaginary = [Double](repeating: 0, count: size)
        transform(real: &real, imaginary: &imaginary)
        return (0...size / 2).map { real[$0] * real[$0] + imaginary[$0] * imaginary[$0] }
    }
}

/// Lawson–Hanson active-set non-negative least squares, driven only by the Gram
/// matrix AᵀA and the correlation Aᵀx. Both are small (one dictionary note per column).
enum NonNegativeLeastSquares {
    static func solve(gram: [Double], correlation: [Double], count: Int) -> [Double] {
        precondition(gram.count == count * count && correlation.count == count)
        var solution = [Double](repeating: 0, count: count)
        var passive: [Int] = []
        var isPassive = [Bool](repeating: false, count: count)
        var blocked = [Bool](repeating: false, count: count)
        let tolerance = 1e-9 * max(1, correlation.max() ?? 1)
        var outer = 0
        while outer < 3 * count {
            outer += 1
            var chosen = -1, best = tolerance
            for index in 0..<count where !isPassive[index] && !blocked[index] {
                var gradient = correlation[index]
                for other in passive { gradient -= gram[index * count + other] * solution[other] }
                if gradient > best { best = gradient; chosen = index }
            }
            guard chosen >= 0 else { break }
            isPassive[chosen] = true; passive.append(chosen)
            var inner = 0
            while inner < 3 * count {
                inner += 1
                guard let trial = solvePassive(gram: gram, correlation: correlation, count: count, passive: passive) else {
                    // Numerically dependent column: never let it re-enter this solve.
                    let last = passive.removeLast()
                    isPassive[last] = false; blocked[last] = true; solution[last] = 0
                    break
                }
                if trial.allSatisfy({ $0 > 0 }) {
                    for (position, index) in passive.enumerated() { solution[index] = trial[position] }
                    break
                }
                var alpha = Double.infinity
                for (position, index) in passive.enumerated() where trial[position] <= 0 {
                    let denominator = solution[index] - trial[position]
                    if denominator > 0 { alpha = min(alpha, solution[index] / denominator) }
                }
                if !alpha.isFinite { alpha = 0 }
                for (position, index) in passive.enumerated() { solution[index] += alpha * (trial[position] - solution[index]) }
                var remaining: [Int] = []
                for index in passive {
                    if solution[index] > 1e-12 { remaining.append(index) }
                    else { solution[index] = 0; isPassive[index] = false }
                }
                passive = remaining
                if passive.isEmpty { break }
            }
        }
        return solution
    }

    /// Unconstrained least squares on the passive columns via Cholesky of the sub-Gram.
    private static func solvePassive(gram: [Double], correlation: [Double], count: Int, passive: [Int]) -> [Double]? {
        let k = passive.count
        guard k > 0 else { return [] }
        var trace = 0.0
        for index in passive { trace += gram[index * count + index] }
        var ridge = 1e-9 * max(1e-12, trace / Double(k))
        for _ in 0..<4 {
            var lower = [Double](repeating: 0, count: k * k)
            var failed = false
            for i in 0..<k {
                for j in 0...i {
                    var sum = gram[passive[i] * count + passive[j]] + (i == j ? ridge : 0)
                    for m in 0..<j { sum -= lower[i * k + m] * lower[j * k + m] }
                    if i == j {
                        guard sum > 1e-14 else { failed = true; break }
                        lower[i * k + i] = sqrt(sum)
                    } else { lower[i * k + j] = sum / lower[j * k + j] }
                }
                if failed { break }
            }
            if failed { ridge *= 100; continue }
            var y = [Double](repeating: 0, count: k)
            for i in 0..<k {
                var sum = correlation[passive[i]]
                for m in 0..<i { sum -= lower[i * k + m] * y[m] }
                y[i] = sum / lower[i * k + i]
            }
            var x = [Double](repeating: 0, count: k)
            for i in stride(from: k - 1, through: 0, by: -1) {
                var sum = y[i]
                for m in (i + 1)..<k { sum -= lower[m * k + i] * x[m] }
                x[i] = sum / lower[i * k + i]
            }
            return x
        }
        return nil
    }
}

/// Fixed-window log-frequency analysis for chord recognition, in the spirit of NNLS
/// chroma (Mauch & Dixon 2010): a Hann-windowed FFT is mapped onto a grid of three bins
/// per semitone, compressed above the noise floor, then decomposed into note saliences
/// with a dictionary of harmonic note profiles by non-negative least squares. The
/// dictionary is generated by pushing ideal windowed sinusoids through the very same
/// mapping, so template widths follow the analysis resolution at every frequency instead
/// of an assumed shape. Everything here is deterministic Swift; no trained weights.
final class ChordSpectrumAnalyzer: Sendable {
    static let binsPerSemitone = 3
    /// C2: the spectrum starts a third below the lowest modelled note so the open sixth
    /// string's wide fundamental peak and the noise-floor estimate have room beneath it.
    static let lowestMIDI = 36
    static let semitoneSpan = 74
    static let binCount = binsPerSemitone * semitoneSpan
    /// Dictionary notes E2 … B6. Nothing below the open sixth string is modelled, so a
    /// D-shaped chord (D3 A3 F♯4) cannot be "explained" as the harmonic series of D2.
    static let lowestNoteMIDI = 40
    static let noteCount = 56
    static let maximumHarmonics = 24

    let sampleRate: Double
    let windowSize: Int
    let harmonicDecay: Double
    let fft: FourierTransform
    let window: [Double]
    let firstFFTBin: Int
    let lastFFTBin: Int
    private let mapOffsets: [Int]
    private let mapTargets: [Int]
    private let mapWeights: [Double]
    /// binCount × noteCount, column major; every column has unit length.
    let dictionary: [Double]
    let gram: [Double]

    static func frequency(ofBin bin: Double) -> Double {
        MusicTheory.frequency(midi: Double(lowestMIDI) + bin / Double(binsPerSemitone))
    }
    static func bin(ofFrequency frequency: Double) -> Double {
        (MusicTheory.midi(frequency: frequency) - Double(lowestMIDI)) * Double(binsPerSemitone)
    }

    init(sampleRate: Double, windowSize: Int, harmonicDecay: Double = ChordTracker.defaultHarmonicDecay) {
        precondition(sampleRate > 0 && windowSize >= 16 && windowSize & (windowSize - 1) == 0)
        self.sampleRate = sampleRate; self.windowSize = windowSize
        self.harmonicDecay = min(0.99, max(0.1, harmonicDecay))
        fft = FourierTransform(size: windowSize)
        window = (0..<windowSize).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(windowSize)) }
        let resolution = sampleRate / Double(windowSize)
        let nyquistBin = windowSize / 2 - 1
        // Every log bin gathers FFT power through a triangular kernel whose half-width is
        // the larger of the log-bin spacing and the FFT resolution, scaled so a sinusoid
        // contributes the same total power wherever it falls.
        var triplets: [(fft: Int, log: Int, weight: Double)] = []
        for k in 0..<Self.binCount {
            let centre = Self.frequency(ofBin: Double(k))
            let spacing = Self.frequency(ofBin: Double(k) + 0.5) - Self.frequency(ofBin: Double(k) - 0.5)
            let halfWidth = max(resolution, spacing)
            let scale = spacing / halfWidth
            let low = max(1, Int(ceil((centre - halfWidth) / resolution)))
            let high = min(nyquistBin, Int(floor((centre + halfWidth) / resolution)))
            guard low <= high else { continue }
            for j in low...high {
                let weight = (1 - abs(Double(j) * resolution - centre) / halfWidth) * scale
                if weight > 1e-9 { triplets.append((j, k, weight)) }
            }
        }
        triplets.sort { $0.fft == $1.fft ? $0.log < $1.log : $0.fft < $1.fft }
        let first = triplets.first?.fft ?? 1, last = triplets.last?.fft ?? 1
        var offsets = [Int](repeating: 0, count: last - first + 2)
        for triplet in triplets { offsets[triplet.fft - first + 1] += 1 }
        for index in 1..<offsets.count { offsets[index] += offsets[index - 1] }
        let targets = triplets.map(\.log), weights = triplets.map(\.weight)
        let map = (offsets: offsets, targets: targets, weights: weights, first: first, last: last)
        // Dictionary: harmonic series with geometric decay, rendered through the analysis operator.
        var dictionary = [Double](repeating: 0, count: Self.binCount * Self.noteCount)
        let topFrequency = Self.frequency(ofBin: Double(Self.binCount)) * 1.02
        for note in 0..<Self.noteCount {
            let fundamental = MusicTheory.frequency(midi: Double(Self.lowestNoteMIDI + note))
            var power = [Double](repeating: 0, count: Self.binCount)
            for harmonic in 1...Self.maximumHarmonics {
                let frequency = fundamental * Double(harmonic)
                guard frequency < topFrequency, frequency < sampleRate / 2 else { break }
                let amplitude = pow(Self.partialAmplitude(harmonic, decay: self.harmonicDecay), 2)
                let centre = frequency / resolution
                let nearest = Int(centre.rounded(.down))
                for j in max(1, nearest - 3)...min(nyquistBin, nearest + 4) {
                    let response = Self.hannResponse(Double(j) - centre, size: windowSize)
                    let value = amplitude * response * response
                    guard value > 0, j >= map.first, j <= map.last else { continue }
                    for position in map.offsets[j - map.first]..<map.offsets[j - map.first + 1] {
                        power[map.targets[position]] += value * map.weights[position]
                    }
                }
            }
            var norm = 0.0
            for k in 0..<Self.binCount { let magnitude = sqrt(power[k]); power[k] = magnitude; norm += magnitude * magnitude }
            norm = sqrt(norm)
            guard norm > 0 else { continue }
            for k in 0..<Self.binCount { dictionary[note * Self.binCount + k] = power[k] / norm }
        }
        firstFFTBin = first; lastFFTBin = last
        mapOffsets = offsets; mapTargets = targets; mapWeights = weights
        self.dictionary = dictionary
        var gram = [Double](repeating: 0, count: Self.noteCount * Self.noteCount)
        for a in 0..<Self.noteCount {
            for b in a..<Self.noteCount {
                var sum = 0.0
                for k in 0..<Self.binCount { sum += dictionary[a * Self.binCount + k] * dictionary[b * Self.binCount + k] }
                gram[a * Self.noteCount + b] = sum; gram[b * Self.noteCount + a] = sum
            }
        }
        self.gram = gram
    }

    static func partialAmplitude(_ harmonic: Int, decay: Double) -> Double { pow(decay, Double(harmonic - 1)) }

    /// Magnitude response of the periodic Hann window at `offset` bins from a sinusoid, relative to N.
    static func hannResponse(_ offset: Double, size: Int) -> Double {
        func dirichlet(_ x: Double) -> Double {
            let n = Double(size)
            if abs(x) < 1e-9 { return n }
            let denominator = sin(.pi * x / n)
            return abs(denominator) < 1e-12 ? n : sin(.pi * x) / denominator
        }
        return abs(0.5 * dirichlet(offset) + 0.25 * dirichlet(offset - 1) + 0.25 * dirichlet(offset + 1)) / Double(size)
    }

    /// Per-bin magnitude of the log-frequency spectrum of one analysis window.
    func logSpectrum(_ samples: [Float]) -> [Double] {
        precondition(samples.count == windowSize)
        var real = [Double](repeating: 0, count: windowSize), imaginary = [Double](repeating: 0, count: windowSize)
        for index in 0..<windowSize { real[index] = Double(samples[index]) * window[index] }
        fft.transform(real: &real, imaginary: &imaginary)
        var spectrum = [Double](repeating: 0, count: Self.binCount)
        for j in firstFFTBin...lastFFTBin {
            let power = real[j] * real[j] + imaginary[j] * imaginary[j]
            guard power > 0 else { continue }
            for position in mapOffsets[j - firstFFTBin]..<mapOffsets[j - firstFFTBin + 1] {
                spectrum[mapTargets[position]] += power * mapWeights[position]
            }
        }
        for k in 0..<Self.binCount { spectrum[k] = sqrt(spectrum[k]) }
        return spectrum
    }

    /// Deviation of the spectral peaks from the semitone grid, in semitones within (-0.5, 0.5].
    static func tuningOffset(_ spectrum: [Double]) -> Double {
        var real = 0.0, imaginary = 0.0
        for (k, value) in spectrum.enumerated() {
            let phase = 2 * Double.pi * Double(k % binsPerSemitone) / Double(binsPerSemitone)
            real += value * cos(phase); imaginary += value * sin(phase)
        }
        guard real * real + imaginary * imaginary > 1e-24 else { return 0 }
        return atan2(imaginary, real) / (2 * .pi)
    }

    /// Resample so that a peak `semitones` above the grid lands on its semitone bin.
    static func shifted(_ spectrum: [Double], semitones: Double) -> [Double] {
        let bins = semitones * Double(binsPerSemitone)
        guard abs(bins) > 1e-6 else { return spectrum }
        return (0..<spectrum.count).map { k in
            let position = Double(k) + bins
            let lower = Int(position.rounded(.down)), fraction = position - Double(lower)
            let a = spectrum.indices.contains(lower) ? spectrum[lower] : 0
            let b = spectrum.indices.contains(lower + 1) ? spectrum[lower + 1] : 0
            return a * (1 - fraction) + b * fraction
        }
    }

    /// Square-root compression above a robust noise floor (the 20th percentile bin). Unlike
    /// Chordino's local standardisation this keeps the harmonic decay that the dictionary
    /// models and does not favour a peak merely because its neighbourhood is empty, so the
    /// six strings of one grip stay comparable even when the top string is much quieter.
    static func compressed(_ spectrum: [Double]) -> [Double] {
        let sorted = spectrum.sorted()
        let floor = sqrt(max(0, sorted[sorted.count / 5]))
        return spectrum.map { max(0, sqrt(max(0, $0)) - floor) }
    }

    /// Non-negative note saliences, E2 … B6, explaining the compressed spectrum.
    func noteSaliences(_ compressed: [Double]) -> [Double] {
        precondition(compressed.count == Self.binCount)
        var correlation = [Double](repeating: 0, count: Self.noteCount)
        for note in 0..<Self.noteCount {
            var sum = 0.0
            for k in 0..<Self.binCount { sum += dictionary[note * Self.binCount + k] * compressed[k] }
            correlation[note] = sum
        }
        return NonNegativeLeastSquares.solve(gram: gram, correlation: correlation, count: Self.noteCount)
    }
}

/// Streaming chord recognition: windows of roughly a third of a second every eighth of a
/// window, tuning compensation from the session's accumulated spectrum, NNLS note
/// saliences folded into treble and bass chroma, then sticky HMM decoding.
public struct ChordTracker {
    /// Geometric decay of the modelled partials in the compressed domain: s² ≈ 0.25 in
    /// amplitude, about −6 dB per partial. Steeper than Chordino's 0.7 for a raw spectrum,
    /// which is what lets a triad voiced like a harmonic series (D3 A3 F♯4) stay three notes.
    public static let defaultHarmonicDecay = 0.5
    public let sampleRate: Double
    public let windowSize: Int
    public let hopSize: Int
    /// Windows quieter than this carry no chord evidence, matching the pitch detector.
    public var minimumRMS = 0.004
    /// Notes below this fraction of the loudest salience are treated as decomposition noise.
    public var salienceFloor = 0.2
    /// A bass pitch class must hold this share of the smoothed bass chroma to be reported.
    public var bassThreshold = 0.35
    public var decoder: ChordDecoder
    private let analyzer: ChordSpectrumAnalyzer
    private var pending: [Float] = []
    private var pendingStartTime = 0.0
    private var nextWindowEnd: Int
    private var tuningAccumulator: [Double]
    private var bassSmoothed = [Double](repeating: 0, count: 12)

    public static func windowSize(for sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return 16384 }
        let exponent = Int(log2(0.34 * sampleRate).rounded())
        return 1 << min(16, max(10, exponent))
    }

    public init(sampleRate: Double, decoder: ChordDecoder = ChordDecoder(), harmonicDecay: Double = ChordTracker.defaultHarmonicDecay) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48000
        self.sampleRate = rate
        windowSize = Self.windowSize(for: rate)
        hopSize = windowSize / 8
        analyzer = ChordSpectrumAnalyzer(sampleRate: rate, windowSize: windowSize, harmonicDecay: harmonicDecay)
        self.decoder = decoder
        nextWindowEnd = windowSize
        tuningAccumulator = [Double](repeating: 0, count: ChordSpectrumAnalyzer.binCount)
    }

    public var windowDuration: Double { Double(windowSize) / sampleRate }
    public var hopDuration: Double { Double(hopSize) / sampleRate }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: true); pendingStartTime = 0; nextWindowEnd = windowSize
        tuningAccumulator = [Double](repeating: 0, count: ChordSpectrumAnalyzer.binCount)
        bassSmoothed = [Double](repeating: 0, count: 12)
        decoder.reset()
    }

    /// Feed consecutive capture samples. Every completed hop yields one entry: a frame,
    /// or nil for a window too quiet to analyse. Timestamps follow the first sample.
    public mutating func consume(_ samples: [Float], startTime: Double, onsetTimestamp: Double?) -> [ChordFrame?] {
        guard !samples.isEmpty, startTime.isFinite else { return [] }
        if pending.isEmpty { pendingStartTime = startTime }
        else if abs(pendingStartTime + Double(pending.count) / sampleRate - startTime) > 0.05 {
            // Dropped or re-timed capture: never stitch two unrelated stretches into one window.
            pending.removeAll(keepingCapacity: true); pendingStartTime = startTime; nextWindowEnd = windowSize
        }
        pending.append(contentsOf: samples)
        var frames: [ChordFrame?] = []
        while nextWindowEnd <= pending.count {
            let window = Array(pending[(nextWindowEnd - windowSize)..<nextWindowEnd])
            let centre = pendingStartTime + (Double(nextWindowEnd) - Double(windowSize) / 2) / sampleRate
            frames.append(analyze(window: window, timestamp: centre, onsetTimestamp: onsetTimestamp))
            nextWindowEnd += hopSize
        }
        let drop = nextWindowEnd - windowSize
        if drop > 0 {
            pending.removeFirst(drop); pendingStartTime += Double(drop) / sampleRate; nextWindowEnd -= drop
        }
        return frames
    }

    /// Analyse one complete window whose centre is `timestamp`.
    public mutating func analyze(window: [Float], timestamp: Double, onsetTimestamp: Double?) -> ChordFrame? {
        precondition(window.count == windowSize)
        var energy = 0.0
        for sample in window { energy += Double(sample) * Double(sample) }
        let rms = sqrt(energy / Double(window.count))
        guard rms >= minimumRMS, rms.isFinite else { decoder.observeSilence(at: timestamp); return nil }
        let spectrum = analyzer.logSpectrum(window)
        for k in tuningAccumulator.indices { tuningAccumulator[k] = 0.85 * tuningAccumulator[k] + 0.15 * spectrum[k] }
        let tuning = ChordSpectrumAnalyzer.tuningOffset(tuningAccumulator)
        let aligned = ChordSpectrumAnalyzer.shifted(spectrum, semitones: tuning)
        var saliences = analyzer.noteSaliences(ChordSpectrumAnalyzer.compressed(aligned))
        let peak = saliences.max() ?? 0
        for index in saliences.indices where saliences[index] < salienceFloor * peak { saliences[index] = 0 }
        saliences = Self.maskingHarmonics(of: saliences)
        var chroma = [Double](repeating: 0, count: 12), bass = [Double](repeating: 0, count: 12)
        var notes: [DetectedNote] = []
        if peak > 0 {
            let lowest = saliences.indices.first { saliences[$0] >= 0.3 * peak } ?? 0
            for (index, salience) in saliences.enumerated() where salience > 0 {
                let midi = ChordSpectrumAnalyzer.lowestNoteMIDI + index
                let relative = salience / peak
                notes.append(DetectedNote(midi: midi, salience: relative))
                let pitchClass = midi % 12
                // A chord is a set of pitch classes: the loudest octave of each class counts,
                // so a root doubled on three strings does not outvote a third played once.
                // The square root keeps a thin top string comparable with a heavy bass string.
                chroma[pitchClass] = max(chroma[pitchClass], sqrt(relative) * Self.trebleWeight(midi))
                // The bass is the lowest sounding note; higher chord tones fade quickly.
                bass[pitchClass] += relative * Self.bassWeight(midi) * exp(-Double(max(0, index - lowest)) / 5)
            }
        }
        let bassTotal = bass.reduce(0, +)
        if bassTotal > 0 { for index in 0..<12 { bass[index] /= bassTotal } }
        for index in 0..<12 { bassSmoothed[index] = 0.6 * bassSmoothed[index] + 0.4 * bass[index] }
        let decision = decoder.decode(chroma: chroma, bassChroma: bass, timestamp: timestamp)
        var heardBass: PitchClass?
        if let strongest = bassSmoothed.indices.max(by: { bassSmoothed[$0] < bassSmoothed[$1] }), bassSmoothed[strongest] >= bassThreshold {
            heardBass = PitchClass(rawValue: strongest)
        }
        let norm = sqrt(chroma.reduce(0) { $0 + $1 * $1 })
        return ChordFrame(timestamp: timestamp, chord: decision.chord.attachingBass(heardBass), confidence: decision.posterior, fit: decision.fit,
                          candidates: decision.candidates, chroma: norm > 0 ? chroma.map { $0 / norm } : chroma, bassChroma: bass, notes: notes,
                          tuningCents: tuning * 100, rms: rms, heldDuration: decision.heldDuration, onsetTimestamp: onsetTimestamp)
    }

    /// Remove decomposition residue that is not a played string. A faint semitone neighbour
    /// of a loud note is leakage of its wide low-frequency peak. A faint note on the 3rd–7th
    /// partial of a much louder note is harmonic energy the fixed-decay dictionary could not
    /// absorb: the 5th and 7th partials would add a major third to every minor chord and a
    /// flat seventh to every triad, so they are removed more readily than the fifths on the
    /// 3rd and 6th, which are usually genuine chord tones. Finally, when every companion of
    /// the loudest note is such a faint partial, the sound is one note rather than a dyad.
    static func maskingHarmonics(of saliences: [Double]) -> [Double] {
        var masked = saliences
        guard let peak = saliences.max(), peak > 0, let strongest = saliences.firstIndex(of: peak) else { return masked }
        for index in saliences.indices where saliences[index] > 0 {
            let left = index > 0 ? saliences[index - 1] : 0, right = index + 1 < saliences.count ? saliences[index + 1] : 0
            if max(left, right) * 0.35 >= saliences[index] { masked[index] = 0 }
        }
        func partial(_ upper: Int, above lower: Int) -> Int? {
            let ratio = pow(2, Double(upper - lower) / 12), nearest = ratio.rounded()
            return abs(1200 * log2(ratio / nearest)) <= 35 ? Int(nearest) : nil
        }
        for upper in masked.indices where masked[upper] > 0 {
            for lower in 0..<upper where masked[lower] > 0 {
                guard let partial = partial(upper, above: lower), (3...7).contains(partial) else { continue }
                let limit = partial == 5 || partial == 7 ? 0.5 : 0.25
                if masked[upper] <= limit * masked[lower] { masked[upper] = 0; break }
            }
        }
        let companions = masked.indices.filter { $0 != strongest && masked[$0] > 0 }
        let onlyPartials = companions.allSatisfy { index in
            index > strongest && masked[index] <= 0.35 * peak && (partial(index, above: strongest) ?? 1) >= 2
        }
        if !companions.isEmpty && onlyPartials { for index in companions { masked[index] = 0 } }
        return masked
    }

    /// Full weight over the range chord tones actually occupy on a guitar; faint weight for
    /// the high register that mostly receives unexplained upper harmonics.
    static func trebleWeight(_ midi: Int) -> Double {
        if midi < 40 { return 0.3 }
        if midi <= 76 { return 1 }
        if midi <= 88 { return 1 - 0.75 * Double(midi - 76) / 12 }
        return 0.1
    }
    /// The bass register: open sixth string up to about D3 in full, fading out by D4.
    static func bassWeight(_ midi: Int) -> Double { max(0, min(1, 1 - Double(midi - 50) / 12)) }

    /// Offline convenience for tests and diagnostics: the whole signal in capture-sized chunks.
    public static func frames(for samples: [Float], sampleRate: Double, chunk: Int = 1024, decoder: ChordDecoder = ChordDecoder(),
                              harmonicDecay: Double = ChordTracker.defaultHarmonicDecay) -> [ChordFrame?] {
        var tracker = ChordTracker(sampleRate: sampleRate, decoder: decoder, harmonicDecay: harmonicDecay)
        var frames: [ChordFrame?] = []
        for start in stride(from: 0, to: samples.count, by: chunk) {
            let end = min(start + chunk, samples.count)
            frames.append(contentsOf: tracker.consume(Array(samples[start..<end]), startTime: Double(start) / sampleRate, onsetTimestamp: nil))
        }
        return frames
    }
}
