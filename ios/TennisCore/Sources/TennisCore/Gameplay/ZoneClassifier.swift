import CoreGraphics

/// Maps a tap point inside a court rect to one of six zone strings.
///
/// Zone layout (net at minY, baseline at maxY):
///   front_court_left   | front_court_right   (near-net row)
///   baseline_left      | baseline_right      (mid row)
///   out_left           | out_right            (deep row)
///
/// Boundary ownership: greater-coordinate side owns every dividing line.
/// Degenerate rect (width ≤ 0 or height ≤ 0): returns "front_court_left".
public enum ZoneClassifier {
    public static func classify(point: CGPoint, in rect: CGRect) -> String {
        // 1. Degenerate guard
        guard rect.width > 0 && rect.height > 0 else { return "front_court_left" }

        // 2. Clamp into rect bounds
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)

        // 3. Column: midX is right-owned (>=)
        let isRight = x >= rect.midX

        // 4. Rows: each boundary is greater-coordinate-owned via strict <
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
