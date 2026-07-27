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
}
