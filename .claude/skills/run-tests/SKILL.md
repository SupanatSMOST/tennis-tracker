---
name: run-tests
description: |
  Standardized test execution for Tennis Shot Tracker's three layers:
  Go backend, Swift iOS, and Python CV pipeline. Provides commands, coverage
  guidance, and output interpretation.
---

# Run Tests Skill

## Go Backend

### Full suite
```bash
cd backend/ && go test ./... 2>&1
```

### Single package
```bash
cd backend/ && go test ./internal/service/... -v 2>&1
```

### Single test by name
```bash
cd backend/ && go test ./... -run TestMatchService_Create -v 2>&1
```

### With coverage
```bash
cd backend/ && go test ./... -coverprofile=coverage.out && go tool cover -func=coverage.out 2>&1
```

### Race detector (integration tests)
```bash
cd backend/ && go test -race ./... 2>&1
```

**Coverage threshold:** ≥ 80% lines for `internal/service/` and `internal/store/`
(handlers tested via integration tests; model package is trivial structs).

## Python CV Pipeline

### Full suite
```bash
cd cv/ && python -m pytest -v 2>&1
```

### Single test
```bash
cd cv/ && python -m pytest tests/test_bounce.py::TestBounceDetector::test_velocity_reversal -v 2>&1
```

### With coverage
```bash
cd cv/ && python -m pytest --cov=pipeline --cov-report=term-missing 2>&1
```

**Coverage threshold:** ≥ 75% for `pipeline/` (CV functions are hard to unit-test fully;
integration tests on real clips are the authoritative check).

## Swift iOS

### Simulator tests
```bash
xcodebuild test \
  -scheme TennisShotTracker \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | xcpretty || cat
```

### Single test class
```bash
xcodebuild test \
  -scheme TennisShotTracker \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing TennisShotTrackerTests/MatchServiceTests \
  2>&1 | tail -30
```

## Interpreting Results

### Go pass
```
ok      tennis/internal/service  0.012s
ok      tennis/internal/store    0.045s
```

### Go failure
```
FAIL    tennis/internal/service  0.008s
--- FAIL: TestMatchService_Create (0.002s)
    match_service_test.go:47: got err=nil, want err "match not found"
```
Parse: package, test name, line, expected vs. actual.

### Python failure
```
FAILED tests/test_zone.py::TestZoneClassifier::test_out_zone - AssertionError
assert "out-left" == "baseline-left"
```

### Swift failure
Look for `Test Case ... failed` lines in xcpretty output. `XCTAssertEqual` failures show `expected: X, but got: Y`.

## Test Organization

```
backend/internal/<layer>/<name>_test.go   # co-located (Go convention)
cv/tests/test_<module>.py                 # pytest discovery
ios/TennisShotTrackerTests/<Name>Tests.swift
```
