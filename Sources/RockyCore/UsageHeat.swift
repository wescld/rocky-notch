import Foundation

/// When an account rate-limit reading should show as a warning.
///
/// A chip carries more than one window — the session one and the weekly one.
/// The hotter of them owns the colour: a calm session sitting on a nearly spent
/// week still has to warn, or the notch reads as reassuring right up to the
/// moment the account stops answering.
public enum UsageHeat {
    /// Used-percentage at or above which a window reads as hot.
    public static let amberThreshold: Double = 80

    /// True when any of the given windows has reached the threshold.
    ///
    /// A missing window is skipped, not counted as cold: an account that never
    /// reported its weekly figure says nothing about it either way, and
    /// treating that silence as 0% would paint a spent week as calm.
    public static func isHot(_ usedPercentages: [Double?]) -> Bool {
        usedPercentages
            .compactMap { $0 }
            .contains { $0 >= amberThreshold }
    }

    /// The highest of the given windows — how close this account is to running
    /// out, whichever window gets there first. Nil when none reported.
    public static func peak(_ usedPercentages: [Double?]) -> Double? {
        usedPercentages.compactMap { $0 }.max()
    }

    /// Whether the first account keeps the space when only one reading fits.
    ///
    /// The hotter account wins: dropping a spent one to show a calm one hides
    /// exactly the figure the amber rule exists to raise. An account that
    /// reported nothing never wins — there would be no number to show. Ties go
    /// to the first, so a strip hovering at the width boundary does not swap
    /// its chip back and forth.
    public static func keepsFirst(_ first: Double?, over second: Double?) -> Bool {
        guard let second else { return true }
        guard let first else { return false }
        return first >= second
    }
}
