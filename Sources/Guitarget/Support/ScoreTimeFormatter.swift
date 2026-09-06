import Foundation
import GuitarCore

enum ScoreTimeFormatter {
    /// A score position at its written tempo, independent of practice speed or count-in.
    static func text(tick: Int, bpm: Double) -> String {
        guard bpm.isFinite, bpm > 0 else { return "—" }
        let seconds = Double(max(0, tick)) * 60 / (bpm * Double(ticksPerQuarter))
        guard seconds.isFinite, seconds < Double(Int.max / 10) else { return "—" }
        let tenths = Int((seconds * 10).rounded(.down))
        return String(format: "%02d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
    }
}
