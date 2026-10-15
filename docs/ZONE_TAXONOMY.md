# Unified Tennis Zone Taxonomy

The application uses a seven-zone taxonomy for classified bounce points:

- `front_court_left`, `front_court_right`
- `baseline_left`, `baseline_right`
- `out_left`, `out_right`
- `out_behind`

Swift TennisCore's `CourtZone` and Go `cvresult.Zone` are the typed representations. CV result decoding and authoritative accepted-record mapping must recognize only these values. `out_behind` is a distinct depth-out classification; left/right out zones remain the deep court row within the supplied court projection.

## Classifier geometry

`ZoneClassifier.classify(point:in:)` takes a court-projection rectangle in CoreGraphics coordinates: `minY` is the net edge, `maxY` is the far baseline, `minX`/`maxX` are the sidelines. A point strictly beyond `maxY` (`point.y > rect.maxY`) is `out_behind` before clamping. A point exactly on the baseline remains in the deep row and resolves to `out_left` or `out_right`. Within the rectangle, `x >= midX` belongs to the right side; the horizontal row boundaries at one-third and two-thirds of height belong to the greater-coordinate/deeper row. Points beyond either sideline are clamped horizontally into the corresponding side; they do not become `out_behind` unless also past the far baseline.

The classifier uses the far baseline as the only depth boundary available in its current API. Near-side out-behind classification would require an explicit second baseline/direction parameter and is intentionally not inferred from this rectangle alone. Invalid/degenerate geometry or non-finite input uses the documented fallback `front_court_left`.

No database migration is needed for the currently modeled shot records if zone values are persisted as unrestricted text; this should be revisited if a future schema introduces a CHECK constraint or database enum. CV result `zone` remains optional and typed validation applies when present.
