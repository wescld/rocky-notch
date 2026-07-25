import SwiftUI

/// The island silhouette: one shape that grows in width and height together as
/// `progress` goes 0 → 1, so opening reads as the notch itself getting bigger.
///
/// The top edge is the whole point. It is always straight and always flush with
/// the screen, in every state, so the panel can never look like it detaches
/// from the hardware cutout. Rounding those corners (the previous `convexTop`
/// mode) let the desktop show through behind them, which is exactly what read
/// as "detached" — and pinning the top to the collapsed width while widening
/// only underneath left a visible step, so the body read as a separate card
/// parked below the notch.
///
/// Everything animates off a single scalar, so the mask, the hit shape and the
/// window's own geometry can never disagree about where the island currently is.
struct NotchShape: InsettableShape {
    /// The flare eats into the usable width, so anything drawn in the cap has
    /// to be inset past it. Exposed so the view insets by the same amount the
    /// shape carves away, in both states.
    static let restFlare: CGFloat = 7
    static let openFlare: CGFloat = 13

    /// 0 = collapsed pill, 1 = fully expanded console.
    var progress: CGFloat
    /// Width while collapsed: the pill fused with the hardware notch.
    var capWidth: CGFloat
    /// Depth of the cap — the notch/menu bar strip the island is fused with.
    var capHeight: CGFloat
    /// Total height once fully expanded.
    var expandedHeight: CGFloat
    /// Concave flare carved just under the top edge, like the hardware cutout.
    var flare: CGFloat = restFlare
    /// Flare once fully open — a wider island needs a wider shoulder, or the
    /// same 7pt notch reads pinched at 560pt across.
    var flareGrowth: CGFloat = openFlare
    var bottomRadius: CGFloat = 18
    /// Amount the path is pulled inward on every edge. Used by `strokeBorder`
    /// so the rim is drawn fully inside the bounds — a centered `stroke` would
    /// clip its outer half against the window and read as a broken border.
    var inset: CGFloat = 0

    /// Both the reveal and the target height interpolate: a session arriving
    /// while the panel is already open grows the island instead of snapping it.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, expandedHeight) }
        set {
            progress = newValue.first
            expandedHeight = newValue.second
        }
    }

    func inset(by amount: CGFloat) -> NotchShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in bounds: CGRect) -> Path {
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return Path() }

        let t = max(0, min(1, progress))
        let cx = rect.midX
        let top = rect.minY

        // One silhouette that grows in both directions at once: the notch
        // itself getting bigger. Pinning the top edge to the collapsed width
        // and widening only underneath produced a visible step, and the body
        // read as a separate card parked below the notch.
        let capHalf = min(capWidth / 2 - inset, rect.width / 2)
        let half = capHalf + (rect.width / 2 - capHalf) * t
        let flare = min(self.flare + (flareGrowth - self.flare) * t, half)
        let wallHalf = half - flare

        let cap = min(max(0, capHeight - inset), rect.height)
        let visible = min(cap + max(0, expandedHeight - inset * 2 - cap) * t, rect.height)
        // The bottom curve has to fit in whatever height is currently revealed,
        // or a short island folds its path back on itself.
        let radius = max(0, min(bottomRadius, (visible - flare) / 2, wallHalf))

        var p = Path()
        // Top edge: always straight, always flush with the screen edge.
        p.move(to: CGPoint(x: cx - half, y: top))
        p.addLine(to: CGPoint(x: cx + half, y: top))
        p.addQuadCurve(
            to: CGPoint(x: cx + wallHalf, y: top + flare),
            control: CGPoint(x: cx + wallHalf, y: top)
        )
        p.addLine(to: CGPoint(x: cx + wallHalf, y: top + visible - radius))
        p.addQuadCurve(
            to: CGPoint(x: cx + wallHalf - radius, y: top + visible),
            control: CGPoint(x: cx + wallHalf, y: top + visible)
        )
        p.addLine(to: CGPoint(x: cx - wallHalf + radius, y: top + visible))
        p.addQuadCurve(
            to: CGPoint(x: cx - wallHalf, y: top + visible - radius),
            control: CGPoint(x: cx - wallHalf, y: top + visible)
        )
        p.addLine(to: CGPoint(x: cx - wallHalf, y: top + flare))
        p.addQuadCurve(
            to: CGPoint(x: cx - half, y: top),
            control: CGPoint(x: cx - wallHalf, y: top)
        )
        p.closeSubpath()
        return p
    }
}
