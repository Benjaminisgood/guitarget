import GuitarCore

/// Per-playback choices; these never write the document/editor's shared transport preferences.
struct AccompanimentPlaybackOptions {
    var loop: Bool
    var metronome: Bool
    var countIn: Bool
    func makeRenderer(score: GuitarScore, sampleRate: Double, fromTick: Int, includeCountIn: Bool) -> ScoreRenderer {
        ScoreRenderer(score: score, sampleRate: sampleRate, speed: 1, fromTick: fromTick,
                      loopRange: loop && score.totalTicks > 0 ? 0..<score.totalTicks : nil,
                      mutedVoices: [], metronome: metronome, countIn: includeCountIn && countIn)
    }
}
