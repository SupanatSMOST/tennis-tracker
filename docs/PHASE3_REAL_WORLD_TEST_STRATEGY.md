# Eva Helion Final Phase: Real-World Seven-Zone Test Strategy

Status: roadmap proposal based on SMOST's directive to test each zone on real-world tennis footage. This document does not claim that footage has been acquired or that the model has passed evaluation.

## Goal and ownership

Beta owns footage sourcing, camera-condition coverage, calibration protocol, homography and inference evaluation harness. Epsilon owns annotation QA, reproducible fixtures, metrics, reporting, and CI test integration. They jointly review the dataset and release gates. Keep the current synthetic/shared golden fixture for contract checks; it supplements, not replaces, this real-footage benchmark.

## Footage sourcing and rights

Build a candidate pool from three sources: (1) broadcast tennis footage with elevated/high-angle court views, (2) fixed high-angle court cameras, and (3) amateur court-camera footage. Prefer public-domain, permissively licensed, or explicitly permissioned footage. Before retaining or processing any clip, record its source, license/permission basis, permitted use, attribution requirements, and retention constraints. Do not assume publicly viewable means reusable. If rights do not permit storage, use an approved controlled-access reference workflow and retain only authorized derived annotations/features. Avoid redistributing source video or committing it to Git. Hash each approved clip, store it in access-controlled storage, and keep stable clip IDs and secure references in the manifest.

## Dataset and sampling plan

Create a manifest keyed by immutable clip ID and SHA-256. Capture source class (broadcast, fixed high-angle, amateur), camera position/view, resolution, frame rate, compression/bitrate when known, orientation, court surface, lighting, occlusions, calibration ID, rights record, split, and annotator/adjudication status. Split by entire match/session/camera setup, never adjacent frames, to prevent leakage. Hold out venues/camera configurations for final evaluation.

Required verified bounce labels cover all seven zones: `front_court_left`, `front_court_right`, `baseline_left`, `baseline_right`, `out_left`, `out_right`, `out_behind`. Include in/out and near-boundary examples; `out_behind` must be demonstrably beyond the far baseline under the documented court-coordinate convention. Use two independent annotators for event frame/time and bounce location/zone, then adjudicate disagreements with frame-by-frame context. Mark occluded/ambiguous/unobservable events as uncertain rather than forcing a label. Track counts per zone, source class, and condition. Do not declare the suite representative until every zone has multiple independent clips and held-out examples; publish the actual counts and limitations.

## Validation dimensions

1. Court homography: annotate court corners and line intersections; estimate image-to-court transform. Report reprojection error in pixels and court coordinates, corner/line residuals, and calibration failure rate per camera/view. Verify coordinate orientation, dimensions, and out-of-court extension.
2. Bounce frame detection: compare predicted event frame/time with adjudicated ground truth. Report precision, recall, F1, false positives per minute, and timestamp error distribution with a predeclared tolerance and explicit event matching rule.
3. Ball tracking and compression robustness: measure track continuity, localization error, fragmentation, and recovery around occlusion. Slice metrics by codec/bitrate, resolution, motion blur, lighting, camera motion, and visible compression artifacts. Do not infer artifact level if source metadata is unavailable; label it unknown or assess blinded by reviewers.
4. Zone classification: report seven-class confusion matrix, per-zone precision/recall/F1, macro average, and boundary-specific accuracy. Count only adjudicated events; publish denominator and confidence intervals. Evaluate against ground-truth bounce location and against predicted location separately to distinguish classifier error from detection/localization error.
5. End-to-end reliability: report the same metrics by broadcast, high-angle fixed, and amateur source classes, plus overall; include failure examples and abstention/low-confidence rates.

## Harness and reproducibility

Provide a deterministic command that consumes a manifest split and pinned model/preprocessing/calibration versions, runs inference, joins predictions to adjudicated annotations, and emits machine-readable per-event results plus a human-readable report and plots. Record repository commit, model/checkpoint digest, runtime/device, preprocessing version, transform parameters, and tool versions. Keep source videos out of version control; small rights-cleared derived metadata and anonymized annotation fixtures may be checked in. Add unit tests for parsing, split isolation, event matching, all-seven-zone taxonomy, metric calculations, and report reproducibility. CI runs contract/unit tests; a separately gated benchmark job runs only on authorized data access, and must not download or redistribute unlicensed footage.

## Proposed gates and deliverables

Beta deliverables: rights-cleared source inventory; calibration and camera coverage protocol; versioned inference/evaluation harness; reproducible homography, detection, tracking, and zone evaluation.

Epsilon deliverables: annotation guide and adjudication log; verified seven-zone manifest with per-zone/source counts; dataset leakage audit; metric implementation tests; benchmark report with confidence intervals, error taxonomy, and limitations.

Before any accuracy claim, agree numerical thresholds with SMOST/product stakeholders and freeze them before viewing final holdout results. The suite must demonstrate at least one verified, adjudicated holdout example in each of the seven zones across the overall set, and should require multiple independent clips per zone to support meaningful generalization claims. Report zone scarcity honestly; do not overstate conclusions from a minimum smoke test. No final-phase sign-off until footage rights are documented, all seven classes are represented, held-out evaluation is clean, and failures are triaged.