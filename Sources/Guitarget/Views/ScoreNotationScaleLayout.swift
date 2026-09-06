import SwiftUI

/// One child, rendered with `.scaleEffect(scale, anchor: .topLeading)`. The
/// transform changes drawing and hit testing; this layout reserves the matching
/// physical size so the enlarged staff and lyric rows do not overlap neighbors.
struct ScoreNotationScaleLayout: Layout {
    let scale: CGFloat

    init(scale: CGFloat) {
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }

    /// Kept independent of subviews so proposal conversion can be checked
    /// without a window. Nil/infinite dimensions request the child's ideal size.
    func unscaledProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        func dimension(_ value: CGFloat?) -> CGFloat? {
            guard let value, value.isFinite else { return nil }
            return max(0, value) / scale
        }
        return ProposedViewSize(width: dimension(proposal.width), height: dimension(proposal.height))
    }

    func scaledSize(_ size: CGSize) -> CGSize {
        func dimension(_ value: CGFloat) -> CGFloat {
            let scaled = value * scale
            return scaled.isFinite ? max(0, scaled) : 0
        }
        return CGSize(width: dimension(size.width), height: dimension(size.height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return scaledSize(child.sizeThatFits(unscaledProposal(proposal)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, anchor: .topLeading, proposal: unscaledProposal(proposal))
    }
}
