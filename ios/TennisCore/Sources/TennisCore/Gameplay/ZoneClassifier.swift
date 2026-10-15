import CoreGraphics

/// Maps a bounce point to one of seven court zones.
/// The supplied rect is the playable court projection: minY is the net and
/// maxY is the baseline. Points strictly beyond maxY classify as out_behind;
/// the baseline itself remains part of the existing court grid.
/// Boundary ownership within the court: greater-coordinate side owns dividers.
public enum ZoneClassifier {
    public static func classify(point: CGPoint, in rect: CGRect) -> String {
        guard rect.width > 0, rect.height > 0,
              point.x.isFinite, point.y.isFinite,
              rect.minX.isFinite, rect.maxX.isFinite,
              rect.minY.isFinite, rect.maxY.isFinite else {
            return "front_court_left"
        }

        // Preserve horizontal out zones. A point beyond the far baseline is
        // distinct regardless of its horizontal position.
        if point.y > rect.maxY { return "out_behind" }

        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        let isRight = x >= rect.midX
        let h = rect.height
        if y < rect.minY + h / 3 {
            return isRight ? "front_court_right" : "front_court_left"
        } else if y < rect.minY + 2 * h / 3 {
            return isRight ? "baseline_right" : "baseline_left"
        } else {
            return isRight ? "out_right" : "out_left"
        }
    }
}
