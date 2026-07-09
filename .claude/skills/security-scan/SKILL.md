---
name: security-scan
description: |
  Security scanning patterns for Tennis Shot Tracker (Go + Swift + Python).
  Provides grep patterns, OWASP Top 10 checklist for each layer,
  and dependency audit commands. Used by the security-auditor agent.
---

# Security Scan Skill

## Quick Scans (run first)

### Secrets Detection
```bash
# Hardcoded credentials in all layers
grep -rn --include="*.go" --include="*.swift" --include="*.py" \
  -iE "(api[_-]?key|secret|password|token|credential)\s*[:=]\s*['\"][^'\"]{8,}" \
  backend/ ios/ cv/ || echo "Clean"

# .env committed
git ls-files | grep -i "\.env" || echo "Clean"

# Private keys
grep -rn "BEGIN.*PRIVATE KEY" . || echo "Clean"
```

### Go — OWASP Top 10

**A01: Broken Access Control**
```bash
# Routes missing auth middleware
grep -rn "router\.\|mux\.\|http\.Handle" backend/internal/handler/ \
  | grep -v "AuthMiddleware\|requireAuth\|verifyToken"
```

**A02: Cryptographic Failures**
```bash
# Weak hashing
grep -rn "md5\|sha1" backend/ --include="*.go" | grep -v "_test\|//\|comment"

# HTTP URLs in config
grep -rn '"http://' backend/ --include="*.go" | grep -v "localhost\|127.0.0.1"
```

**A03: Injection**
```bash
# SQL string building (must use pgx named params)
grep -rn "fmt\.Sprintf.*SELECT\|fmt\.Sprintf.*INSERT\|fmt\.Sprintf.*UPDATE\|fmt\.Sprintf.*DELETE" backend/ || echo "Clean"

# Command injection
grep -rn "exec\.Command\|os\.StartProcess" backend/ | grep -v "_test"
```

**A07: Auth & Session**
```bash
# JWT signed without expiry
grep -A5 "jwt\.NewWithClaims\|jwt\.New" backend/ -rn | grep -v "ExpiresAt\|exp" | head -20

# bcrypt rounds too low (< 12 is weak)
grep -rn "bcrypt\.GenerateFromPassword" backend/ | grep -v "bcrypt\.DefaultCost\|Cost: 1[2-9]\|Cost: [2-9][0-9]"
```

**A09: Logging**
```bash
# Sensitive data in slog calls
grep -rn 'slog\.\(Info\|Warn\|Error\|Debug\).*\(password\|token\|secret\|hash\)' backend/ || echo "Clean"
```

### Swift — OWASP

**Token storage (A02):**
```bash
# Must not use UserDefaults for sensitive data
grep -rn "UserDefaults.*set\|UserDefaults.*string" ios/ \
  | grep -i "token\|jwt\|auth\|password\|secret" || echo "Clean"
```

**Transport (A02):**
```bash
# HTTP in API base URL
grep -rn '"http://' ios/ | grep -v "localhost\|127.0.0.1\|//" || echo "Clean"
```

**Auth bypass (A07):**
```bash
# Force-unwrap on auth-sensitive paths
grep -rn "token!\|userId!\|jwt!" ios/ || echo "Clean"
```

**Data exposure (A05):**
```bash
# Print statements logging sensitive fields
grep -rn "print.*token\|print.*password\|NSLog.*token" ios/ || echo "Clean"
```

### Python (CV) — OWASP

**A03: Injection**
```bash
# eval / exec in pipeline code
grep -rn "eval(\|exec(" cv/pipeline/ | grep -v "#" || echo "Clean"
```

**A08: Unsafe deserialization**
```bash
# Pickle of untrusted data
grep -rn "pickle\.loads\|pickle\.load" cv/ | grep -v "# safe:" || echo "Clean"

# Torch load without weights_only=True
grep -rn "torch\.load(" cv/ | grep -v "weights_only=True" || echo "Clean"
```

## Dependency Audit

### Go
```bash
cd backend/
# Check for known vulnerabilities
govulncheck ./... 2>/dev/null || echo "govulncheck not installed — install: go install golang.org/x/vuln/cmd/govulncheck@latest"
go list -m all | grep -i "CVE" || echo "Clean (no CVE in module names)"
```

### Python
```bash
cd cv/
pip-audit 2>/dev/null || echo "pip-audit not installed — install: pip install pip-audit"
```

## Report Format
```
### [SEVERITY] CWE-<N> — <Title>
- **File:** `path/file.go:42`
- **Code:** `<offending snippet>`
- **Risk:** <what an attacker could do>
- **Fix:** <concrete remediation>
```

Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
