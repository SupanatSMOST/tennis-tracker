# Eva Helion Phase 1: CV Architecture, Contract, and Validation

Status: proposal for review; no inference runtime or CV integration is claimed complete by this document.

## Beta research synthesis

TrackNet is a heatmap-based temporal detector built for small, blurry, fast tennis balls. It uses consecutive frames to exploit flight patterns and can handle some occlusion better than independent per-frame object detection. The original paper reports 640x360 inputs and cross-validation performance materially lower than its best single-video figures, a useful warning against relying on headline metrics. TrackNet-family variants are candidates, not drop-in validated CoreML models. TrackNetV2 is primarily associated with shuttlecock tracking; TrackNetV3 work described in available references is also badminton-focused and should not be assumed tennis-generalizable. TrackNetV4 research investigates motion-attention maps for fast small-object tracking, but should be treated as a research baseline pending license, implementation, dataset, and deployment review.

Recommended candidates for a controlled comparison:
1. Existing TrackNet-family baseline in the repository spike, using consecutive frames/heatmap output.
2. A compact temporal CNN or small heatmap network designed for fixed-camera phone clips; constrain input resolution/crop and quantify lost recall.
3. A classical trajectory/event baseline over detected points: robust smoothing/interpolation for short gaps, then detect a candidate bounce as a ground-plane trajectory discontinuity/vertical-velocity reversal, with court geometry and temporal plausibility. This is inexpensive and interpretable but sensitive to sparse/noisy tracks, rolling shutter, perspective, occlusion, and frame rate. Fit trajectories only over short locally valid intervals; do not bridge long gaps and fabricate a bounce.

Bounce detection is a distinct stage from ball localization. Evaluate detector recall and bounce-event precision/recall separately, then evaluate mapped correct-zone accuracy using labeled bounces. Homography maps image points to court-plane coordinates; it cannot turn an airborne point into its true landing point without a bounce/landing estimate. Camera calibration, timestamp accuracy, video frame rate, and court coordinate conventions are first-class inputs.

## ADR-001: inference location

Decision: defer final runtime selection until a representative labeled-footage gate; use a platform-neutral CV result contract and keep the manual review flow usable independently of model choice. Preferred production target is on-device CoreML if the chosen model converts cleanly, runs reliably on the supported iPhone matrix, meets latency/memory/thermal requirements, and keeps video local. Core ML can schedule work across available compute units; Neural Engine use is not guaranteed merely by model conversion. Validate actual device execution and operator support; compare CPU/GPU/ANE configuration and numerical behavior.

Alternative: offline backend inference worker. It simplifies Python research-model reuse and can use larger models/hardware, but uploads sensitive video, adds network/queue/storage/security/retention costs, and requires worker operations and failure/retry handling. Choose this only with explicit privacy/consent, bounded upload and retention, authenticated jobs, encryption, deletion controls, and measured end-to-end turnaround. Do not silently upload under a design that promises local video.

Gate: run identical labeled inputs through candidates; meet at least the project’s stated >=80% correct-zone localization target (and report uncertainty, per-condition results, event precision/recall and recall, not just aggregate accuracy); demonstrate supported-device performance and licensing. If neither passes, do not ship automatic labeling as reliable; ship manual-only review or continue research.

## Fallback UX: confidence-gated playback review

Process after recording and show a scrubber with candidate bounce markers. A candidate above a calibrated high-confidence threshold may be preselected but remains user-reviewable. Medium/low confidence and unlocalized candidates must be visibly flagged and require user action: scrub to the event, pause/step frames, tap the bounce/landing point on the court overlay, and confirm/edit the zone. Provide add, remove, undo, and “not a landing / unknown” actions. Never silently drop low-confidence events or convert them into asserted automatic stats. Keep source=`cv` only for accepted automatic detections and source=`manual` for user-entered/corrected records; retain model confidence/version and correction audit data where appropriate. Ensure the zone classifier and court overlay use the exact calibrated coordinate convention.

Thresholds are empirical, not invented constants: select them from a held-out validation set to meet a stated precision/coverage tradeoff. Always offer manual review for unmarked intervals because detector confidence cannot establish that no event occurred.

## CV result JSON schema (contract proposal)

One job result describes one match/video and a list of candidate bounce events. Coordinates are normalized image coordinates in [0,1] (origin upper-left) and court coordinates use the calibration’s documented court-plane units/origin. `confidence` is a calibrated value in [0,1], or null when unavailable. `zone` is the fixed product taxonomy string or null when unresolved. Preserve clip-relative timestamps in integer milliseconds. Consumers must reject unsupported schema versions, invalid ranges, duplicate IDs, and malformed timestamps.

```json
{
  "schema_version": "1.0",
  "match_id": "uuid",
  "video": {"duration_ms": 123400, "width": 1920, "height": 1080, "fps": 60.0},
  "calibration_id": "uuid",
  "model": {"name": "tracknet-family", "version": "candidate-1", "runtime": "coreml", "sha256": "optional-digest"},
  "events": [
    {
      "event_id": "uuid",
      "event_type": "bounce",
      "timestamp_ms": 12345,
      "image_point": {"x": 0.51, "y": 0.72},
      "court_point": {"x": 0.42, "y": 0.81},
      "zone": "baseline_left",
      "confidence": 0.83,
      "review_status": "needs_review"
    }
  ]
}
```

`runtime` is `coreml` or a specifically named worker runtime; `sha256` is optional until artifacts are versioned. `review_status` is `needs_review`, `accepted`, `corrected`, `rejected`, or `unresolved`. Server persistence should map accepted records to existing fields and preserve existing API behavior; do not persist unreviewed detections as authoritative records. `court_point` and `zone` may be null if calibration/mapping fails. Version and taxonomy compatibility must be checked at the boundary.

## Gamma codebase/build work checklist

- Backend: Go module declares Go 1.25.0; verify toolchain compatibility in CI and use `go test ./...`, `go vet ./...`, plus DB-backed tests with a disposable PostgreSQL service and migrations applied. Check Docker daemon availability separately from Dockerfile syntax/build; test clean Compose startup including db health, goose migration completion, app readiness, and shutdown.
- PostgreSQL: migrations 00001 auth, 00002 gameplay tables, 00003 gameplay indexes; test both fresh install and upgrade path, ownership isolation, transaction rollback, summary rebuild after edits, and timestamps.
- Compose: verify `.env.example` variables match compose and database URL host/service name; verify migrate uses the expected image and DB URL; ensure secrets are not committed and health/readiness is actionable.
- iOS: inspect TennisCore `Package.swift`, sources/tests, app target deployment settings, and camera permission keys. Run `swift test` in TennisCore and an Xcode simulator/device build for the app; Swift package tests alone do not verify camera permissions or app target integration.
- Documentation: root README is product-specific. `files/README.md` had unrelated agentic-SDLC text and is replaced with a concise product overview. Do not claim test/build success without actual execution output.

## Epsilon validation and benchmark plan

1. Inventory tests and record current count from `swift test` output; reconcile the reported 118 tests against the current main/feature branch. Run `go test ./...`, `go vet ./...`, DB integration tests, migrations, and full iOS simulator build. Capture commit SHA, exact commands, environment, and results. Avoid treating skipped DB tests as passed integration coverage.
2. CV dataset: public footage and fixed phone footage with all four court corners visible; hand-label 30–50 bounces per clip (as SPIKE_RESULT requests) with frame/timestamp and true zone; reserve a held-out clip/court condition. Verify dataset/model licenses and consent.
3. Metrics: ball-point precision/recall/F1; track continuity and gap length; bounce event precision/recall/F1 and timestamp error; correct-zone accuracy and confusion matrix; coverage versus confidence threshold; false positives per minute; calibration reprojection error. Report by lighting, camera angle, resolution, court surface, serve/rally, occlusion, and near-line/out cases. Specify denominator and uncertainty.
4. Runtime: supported iPhone model/iOS matrix, cold model load, processing time per minute of video, peak memory, energy/thermal impact, crash rate, and result determinism. For worker alternative, add upload time, queue time, processing time, egress/storage, retry and deletion verification.
5. E2E: record → process → review → correct/add/remove → save → summary; cover zero/partial detections, invalid calibration, interrupted processing, offline/retry, duplicate events, malformed schema, and app termination/relaunch. Verify shot counts match accepted records exactly.
6. Release gate: >=80% correct-zone localization on the defined held-out evaluation (project design criterion), publish event detection/coverage and per-condition results, manual fallback verified, CI green, clean Compose/database migration validated, privacy/licensing/deployment docs complete. If gate fails, release manual tagging only and label automatic results experimental.

## Research sources

- TrackNet original paper, abstract and methods summary: https://arxiv.org/abs/1907.03698
- TrackNetV3 repository (badminton-focused model; not direct tennis evidence): https://github.com/qaz812345/TrackNetV3
- TrackNetV4 paper/repository discovery: https://research-repository.griffith.edu.au/bitstreams/d8c2bb34-c87c-44f5-b358-63e8d2e6a9fa/download
- Core ML Tools model prediction and compute-unit guide: https://apple.github.io/coremltools/docs-guides/source/model-prediction.html
- Repository design and spike results: `DESIGN.md`, `SPIKE.md`, `SPIKE_RESULT.md`.
