import Foundation

/// How a swipe moves and turns pages.
public enum Paging {
    /// Trackpad: how far to swipe before the page turns (horizontal / vertical). Speed doesn't matter.
    public static let threshold = 50.0
    public static let verticalThreshold = 10.0

    /// Where the pages sit for a swipe of `d` points on a screen `width` wide: 1:1 up to a short distance
    /// (8% of the width, kept between 48 and 72 pt), then with growing resistance, never more than 180 pt further.
    public static func follow(_ d: Double, width: Double) -> Double {
        let limit = min(72, max(48, width * 0.08))
        let distance = abs(d)
        guard distance > limit else { return d }
        let extra = distance - limit
        return (limit + extra * 180 / (extra + 180)) * (d < 0 ? -1 : 1)
    }

    /// The page change for a finished swipe: +1 (next), -1 (previous) or 0. While the previous page turn is still
    /// settling, any swipe turns the page again in its direction.
    public static func turn(offset: Double, threshold: Double, settling: Bool) -> Int {
        if offset < -threshold || (settling && offset < 0) { return 1 }
        if offset > threshold || (settling && offset > 0) { return -1 }
        return 0
    }
}
