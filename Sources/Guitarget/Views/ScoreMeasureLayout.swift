import Foundation

enum ScoreMeasureLayout {
    static func columnCount(availableWidth: CGFloat, preferredCount: Int, minimumMeasureWidth: CGFloat) -> Int {
        if [1, 2, 4].contains(preferredCount) { return preferredCount }
        guard availableWidth.isFinite, minimumMeasureWidth.isFinite else { return 1 }
        let spacing: CGFloat = 14
        let fitting = floor((max(0, availableWidth) + spacing) / (max(1, minimumMeasureWidth) + spacing))
        return Int(min(4, max(1, fitting)))
    }
}
